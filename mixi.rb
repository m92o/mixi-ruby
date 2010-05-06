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

  REDIRECT = "&redirect=recent_voice.pl"

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
  def add_echo(message)
    path = "/add_voice.pl"

    raise ArgumentError, "Too long (>150)" if message.length > 150

    body = "body=" + CGI.escape(euc_conv(message)) + "#{@post_key}#{REDIRECT}"
    request(POST, path, body)
  end

  # reply echo (返信)
  def reply_echo(message, member_id, post_time)
    path = "/system/rpc.json"

    raise ArgumentError, "Too long (>150)" if message.length > 150

    encode_message = utf8_conv(message)

    body = "{\"jsonrpc\": \"2.0\", \"method\": \"Voice.InsertComment\", \"params\": {\"member_id\": \"#{member_id}\", \"post_time\": \"#{post_time}\", \"comment_member_id\": \"#{@member_id}\", \"body\": \"#{encode_message}\", \"auth_key\": \"#{@auth_key}\"}, \"id\": 0}"
    request(POST, path, body)
  end

  # delete echo (ボイス削除)
  def delete_echo(post_time)
    path = "/delete_voice.pl"
    param = "?post_time=#{post_time}#{@post_key}#{REDIRECT}"
    request(GET, path + param)
  end

  # delete response (返信ボイス削除)
  def delete_response(member_id, post_time, comment_member_id, comment_post_time)
    path = "/system/rpc.json"
    body = "{\"jsonrpc\": \"2.0\", \"method\": \"Voice.DeleteComment\", \"params\": {\"member_id\": \"#{member_id}\", \"post_time\": \"#{post_time}\", \"comment_member_id\": \"#{comment_member_id}\", \"comment_post_time\": \"#{comment_post_time}\", \"auth_key\": \"#{@auth_key}\"}, \"id\": 0}"
    request(POST, path, body)
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

  # edit account echo (ボイス公開範囲設定)
  def edit_account_echo(level)
    path = "/edit_account_voice.pl"

    raise ArgumentError, "Invalid parameter method: #{method}" if level < LEVEL_FRIEND && level > LEVEL_ALL

    body = "mode=commit&voice_level=#{level}#{@post_key_edit}"

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
      path = "/recent_voice.pl"
    when :list
      path = "/list_voice.pl"
      path += "?id=#{member_id}" if member_id != nil
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

    archives = Nokogiri::HTML(html).search('div[@class="voiceArchives"]/ul[@class="listArea"]/li[class="archive"]')
    archives.each do |archive|
      thumb_url = archive.at('div[@class="thumbArea"]/span/a/img').attribute('src')
      member_id = archive.at('input[@class="memberId"]').attribute('value')
      nickname = archive.at('input[@class="nickname"]').attribute('value')
      comment = archive.at('div[@class="voiceArea"]/div[@class="voiceWrap"]/div/p').text
      comment.slice!(comment.rindex('('), comment.length)
      post_time = archive.at('input[@class="postTime"]').attribute('value')
      time_message = archive.at('div[@class="voiceArea"]/div[@class="voiceWrap"]/div/p/span/a').text

      res = []
      morelink = archive.search('div[@class="voiceArea"]/div[@class="voiceWrap"]/div[@class="resArea"]/div/p[@class="moreLink01 hrule"]')
      if morelink.length > 0
        path = "/" + morelink.at('a').attribute('href');
        response = request(GET, path);
        comments = Nokogiri::HTML(response.body).search('div[@class="commentList"]/dl[class="comment"]/dd')
      else
        comments = archive.search('div[@class="voiceArea"]/div[@class="voiceWrap"]/div[@class="resArea"]/div/dl[@class="comment"]/dd')
      end
      comments.each do |row|
        res_thumb_url = row.at('span/a/img').attribute('src')
        res_member_id = row.at('input[@class="commentMemberId"]').attribute('value')
        res_nickname = row.at('div/a').text
        res_comment = row.at('div/p').text
        res_comment.slice!(res_comment.rindex('('), res_comment.length)
        res_post_time = row.at('input[@class="commentPostTime"]').attribute('value')
        res_time_message = row.at('div/p/span').text

        res << Voice.new(res_member_id, res_nickname, res_comment, res_post_time, res_time_message, res_thumb_url, nil)
      end

      lists << Voice.new(member_id, nickname, comment, post_time, time_message, thumb_url, res)
    end

    return lists
  end
  private :echo_lists

  def get_post_key
    res = request(GET, "/recent_voice.pl")
    @auth_key = Nokogiri::HTML(res.body).at('input[@id="post_key"]').attribute('value')
    @post_key = "&post_key=" + @auth_key

    # 設定時に必要なキー
    res = request(GET, "/edit_account_voice.pl")
    @post_key_edit = "&post_key=" + Nokogiri::HTML(res.body).at('input[@name="post_key"]').attribute('value')
  end
  private :get_post_key

  # euc-jpに変換
  def euc_conv(string)
    return (RUBY_VERSION < "1.9") ? Kconv.toeuc(string) : string.encode("EUC-JP")
  end
  private :euc_conv

  def utf8_conv(string)
    return (RUBY_VERSION < "1.9") ? Kconv.toutf8(string) : string.encode("UTF-8")
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

  # ボイス情報
  class Voice
    attr_reader :member_id, :nickname, :comment, :post_time, :time_message, :thumb_url, :response

    def initialize(member_id, nickname, comment, post_time, time_message, thumb_url, response)
      @member_id = member_id
      @nickname = nickname
      @comment = comment
      @post_time = post_time
      @time_message = time_message
      @thumb_url = thumb_url
      @response = response
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
