# -*- coding: utf-8 -*-
#
# show.rb
#  mixiボイスのつぶやき表示
#
require 'mixi'

user = "USERNAME"
pass = "PASSWORD"
ssl = false

def show_voice(voices)
  voices.each do |voice|
    puts "#{voice.nickname} #{voice.comment} #{voice.time_message} #{voice.member_id} #{voice.post_time}"
    puts voice.thumb_url
    voice.response.each do |res|
      puts "> #{res.nickname} #{res.comment} #{res.time_message} #{res.member_id} #{res.post_time}"
      puts "> #{res.thumb_url}"
    end
  end
end

mixi = Mixi.new(user, pass, ssl)
mixi.login
voices = mixi.list_echo
show_voice(voices)
