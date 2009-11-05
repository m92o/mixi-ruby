# -*- coding: utf-8 -*-
#
# mixi.rb
#
# Mixiクライアントクラス
#
require 'net/https'
require 'cgi'
require 'rexml/document'
require 'rss'
if RUBY_VERSION < "1.9"
  require 'kconv'
end
require 'rubygems'
require 'nokogiri'

class Mixi
  HOST = "mixi.jp"
  HTTP_PORT = 80
  HTTPS_PORT = 443
  GET = :get
  POST = :post

  # エコーリストの種類
  RECENT_ECHO = :recent
  LIST_ECHO = :list
  RES_ECHO = :res

  REDIRECT = "&redirect=recent_echo"

  # ボイスの公開範囲
  LEVEL_ALL = 4
  LEVEL_FRIEND_FRIEND = 3
  LEVEL_FRIEND = 2

  # お知らせの種類
  UPDATE_DIARY = :diary
  UPDATE_COMMENT = :comment
  UPDATE_BBS = :bbs
  UPDATE_ALBUM = :album
  UPDATE_VIDEO = :video

  # 自分のメンバーID
  attr_reader :member_id

  def initialize(user, pass, use_ssl = false)
    @user = user
    @pass = pass
    @use_ssl = use_ssl
    @cookie = nil
  end

  # ログイン
  def login()
    path = "/login.pl"

    email = "email=#{@user}"
    password = "&password=#{@pass}"
    next_url = "&next_url=/home.pl"

    body = email + password + next_url # next_urlがないとクッキー貰えないみたい
    response = request(POST, path, body)

    return if response == nil

    # セッション情報
    cookie = response.fetch('set-cookie')
    bf_session = cookie.slice(/BF_SESSION=.*?;/)
    bf_stamp = cookie.slice(/BF_STAMP=.*?;/)
    @cookie = "#{bf_session} #{bf_stamp}"

    # ログイン後、SSLが有効なままだと何故か動かないので無効にする(要調査)
    @use_ssl = false

    # post_key取得
    get_post_key

    # member_id取得
    get_member_id
  end

  # add echo (発言)
  #  返信の場合は、返信したいボイスのmember_idとpost_timeを指定
  def add_echo(message, member_id = nil, post_time = nil)
    path = "/add_echo.pl"

    raise ArgumentError, "Too long (>150)" if message.length > 150

    # body
    res = (member_id != nil && post_time != nil) ? "&parent_member_id=#{member_id}&parent_post_time=#{post_time}" : ""
    body = "body=" + CGI.escape(euc_conv(message)) + "#{res}#{@post_key}#{REDIRECT}"

    request(POST, path, body)
  end

  # delete echo (ボイス削除)
  def delete_echo(post_time)
    path = "/delete_echo.pl"
    param = "?post_time=#{post_time}#{@post_key}#{REDIRECT}"

    request(GET, path + param)
  end

  # recent echo (マイミクのボイス)
  def recent_echo
    return _get_echoes(RECENT_ECHO)
  end

  # list echo (指定ユーザのボイス)
  #  member_idをしてしないと自分のボイス
  def list_echo(member_id = nil)
    return _get_echoes(LIST_ECHO, member_id)
  end

  # res echo (自分宛の返信ボイス)
  def res_echo
    return _get_echoes(RES_ECHO)
  end

  # edit account echo (ボイス公開範囲設定)
  def edit_account_echo(level)
    path = "/edit_account_echo.pl"

    raise ArgumentError, "Invalid parameter method: #{method}" if level < LEVEL_FRIEND && level > LEVEL_ALL

    body = "mode=finish&echo_level=#{level}#{@post_key_edit}"

    request(POST, path, body)
  end

  # 新着情報取得
  #  typeを指定しない場合は全ジャンル
  def updates(member_id = @member_id, type = nil)
    path = "/atom/updates/r=1/member_id=#{member_id}"
    case type
    when :diary
      path += "/-/diary"
    when :comment
      path += "/-/comment"
    when :bbs
      path += "/-/bbs"
    when :album
      path += "/-/album"
    when :video
      path += "/-/video"
    end

    items = []
    res = request(GET, path)
    RSS::Parser.parse(res.body).items.each do |item|
      items << Update.new(item.category.label, item.link.href, item.title.content, item.summary.content, item.author.name.content, item.updated.content)
    end

    return items
  end

  # マイミク情報取得
  def friends(member_id = @member_id)
    path = "/atom/friends/r=1/member_id=#{member_id}"

    items = []
    res = request(GET, path)
    # RSS::Atom だと invalid なので REXML を使う
    REXML::Document.new(res.body).elements.each('feed/entry') do |entry|
      items << User.new(entry.elements['id'].text.sub(/^.*-/, ""), entry.elements['title'].text, entry.elements['updated'].text, entry.elements['icon'].text)
    end

    return items
  end

  # 足跡情報取得
  def tracks(member_id = @member_id)
    path = "/atom/tracks/r=2/member_id=#{member_id}"

    items = []
    res = request(GET, path)
    RSS::Parser.parse(res.body).items.each do |item|
      items << Track.new(item.author.name.content, item.updated.content, item.link.href)
    end

    return items
  end

  # お知らせ情報取得
  def notify(member_id = @member_id)
    path = "/atom/notify/r=2/member_id=#{member_id}"
    # 意味のある情報がないようなので未実装
  end

  # メンバーID取得
  def get_member_id
    path = "/atom/updates/r=1"

    res = request(GET, path)
    doc = REXML::Document.new(res.body)
    href = doc.elements['service/workspace/collection'].attribute("href").to_s
    @member_id = href.sub(/^.*member_id=/, "")
  end
  private :get_member_id

  # エコーリスト取得
  def _get_echoes(type, member_id = nil)
    case type
    when :recent
      path = "/recent_echo.pl"
    when :list
      path = "/list_echo.pl"
      path += "?id=#{member_id}" if member_id != nil
    when :res
      path = "/res_echo.pl"
    else
      raise ArgumentError, "Invalid parameter method: #{method}"
    end

    res = request(GET, path)
    return echo_lists(res.body)
  end
  private :_get_echoes

  # htmlからエコーリスト取り出す
  def echo_lists(html)
    lists = []

    trs = Nokogiri::HTML(html).search('div[@class="archiveList"]/table/tr')
    trs.each do |tr|
      thumb_url = tr.at('td[@class="thumb"]/a/img').attribute('src')
      member_id = tr.at('div[@class="echo_member_id"]').text
      nickname = tr.at('div[@class="echo_nickname"]').text
      comment = tr.at('div[@class="echo_body"]').text
      post_time = tr.at('div[@class="echo_post_time"]').text
      time_message = tr.at('td[@class="comment"]/span/a').text

      lists << Echo.new(member_id, nickname, comment, post_time, time_message, thumb_url)
    end

    return lists
  end
  private :echo_lists

  # htmlからpost_keyを取り出す
  def get_post_key
    # 発言、削除時に必要なキー
    res = request(GET, "/recent_echo.pl")
    @post_key = "&post_key=" + Nokogiri::HTML(res.body).at('input[@id="post_key"]').attribute('value')

    # 設定時に必要なキー
    res = request(GET, "/edit_account_echo.pl")
    @post_key_edit = "&post_key=" + Nokogiri::HTML(res.body).at('input[@name="post_key"]').attribute('value')
  end
  private :get_post_key

  # euc-jpに変換
  def euc_conv(string)
    return (RUBY_VERSION < "1.9") ? Kconv.toeuc(string) : string.encode("EUC-JP")
  end
  private :euc_conv

  # http request
  def request(method, path, body = nil)
    case method
    when :get
      req = Net::HTTP::Get.new(path)
    when :post
      req = Net::HTTP::Post.new(path)
    else
      raise ArgumentError, "Invalid parameter method: #{method}"
    end
    req.add_field("Cookie", @cookie) if @cookie != nil
    req.body = body if body != nil

    port = (@use_ssl == true) ? HTTPS_PORT : HTTP_PORT

    http = Net::HTTP.new(HOST, port)
    http.use_ssl = @use_ssl
    http.verify_mode = OpenSSL::SSL::VERIFY_NONE if @use_ssl == true # とりあえず未チェック

    response = http.start do |h|
      h.request(req)
    end

    if response.class != Net::HTTPOK && response.class != Net::HTTPFound
      return nil # 例外の方がいいかな？
    end

    return response
  end
  private :request

  # エコー情報
  class Echo
    attr_reader :member_id, :nickname, :comment, :post_time, :time_message, :thumb_url

    def initialize(member_id, nickname, comment, post_time, time_message, thumb_url)
      @member_id = member_id
      @nickname = nickname
      @comment = comment
      @post_time = post_time
      @time_message = time_message
      @thumb_url = thumb_url
    end
  end

  # 足跡情報
  class Track
    attr_reader :name, :updated, :link

    def initialize(name, updated, link)
      @name = name
      @updated = updated
      @link = link
    end
  end

  # 更新情報
  class Update
    attr_reader :category, :link, :title, :summary, :name, :updated

    def initialize(category, link, title, summary, name, updated)
      @category = category
      @link = link
      @title = title
      @summary = summary
      @name = name
      @updated = updated
    end
  end

  # ユーザ情報
  class User
    attr_reader :id, :name, :updated, :icon_url

    def initialize(id, name, updated, icon_url)
      @id = id
      @name = name
      @updated = updated
      @icon_url = icon_url
    end
  end
end
