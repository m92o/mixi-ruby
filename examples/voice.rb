# -*- coding: utf-8 -*-
#
# voice.rb
#  mixiボイスでつぶやく
#
require 'mixi'

user = "USERNAME"
pass = "PASSSWORD"
ssl = false

if ARGV.length != 1
  puts "usage: #{$0} message"
  exit 1
end
message = ARGV[0]

mixi = Mixi.new(user, pass, ssl)
mixi.login
mixi.add_echo(message)
