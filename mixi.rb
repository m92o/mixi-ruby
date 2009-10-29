# -*- coding: utf-8 -*-
#
# mixi.rb
#
# Mixiクライアントクラス
#
require 'net/https'
require 'cgi'
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
    @cookie = ""
    response.get_fields('set-cookie').each do |cookie|
      @cookie << cookie.gsub("path=/", "")
    end

    # ログイン後、SSLが有効なままだと何故か動かないので無効にする(要調査)
    @use_ssl = false

    # post_key取得
    get_post_key
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

    raise ArgumentError, "Invalid parameter method: #{method}" if level < 2 && level > 4

    body_finish = "mode=finish&echo_level=#{level}#{@post_key_edit}"

    request(POST, path, body_finish)
  end

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
    echo_lists = []

    trs = Nokogiri::HTML(html).search('div[@class="archiveList"]/table/tr')
    trs.each do |tr|
      thumb_url = tr.at('td[@class="thumb"]/a/img').attribute('src')
      member_id = tr.at('div[@class="echo_member_id"]').text
      nickname = tr.at('div[@class="echo_nickname"]').text
      comment = tr.at('div[@class="echo_body"]').text
      post_time = tr.at('div[@class="echo_post_time"]').text
      time_message = tr.at('td[@class="comment"]/span/a').text

      echo_lists << Echo.new(member_id, nickname, comment, post_time, time_message, thumb_url)
    end

    return echo_lists
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
end