#!/usr/local/bin/ruby
# encoding: UTF-8

require "socket"
require 'string-irc'
require 'net/http'
require 'htmlentities'
require 'logger'
require 'fileutils'
require 'open-uri'
require 'nokogiri'
require 'yaml'

# Don't allow use of "tainted" data by potentially dangerous operations
#$SAFE=1

class Numeric
  def to_time_ago
    time_ago = self
    time_unit = 'seconds'

    if time_ago / 60 >= 1
      time_ago /= 60
      time_unit = time_ago == 1 ? 'minute' : 'minutes' 

      if time_ago / 60 >= 1
        time_ago /= 60
        time_unit = time_ago == 1 ? 'hour' : 'hours'

        if time_ago / 24 >= 1
          time_ago /= 24
          time_unit = time_ago == 1 ? 'day' : 'days'
        end
      end
    end

    "#{time_ago.round(1)} #{time_unit}"
  end
end

class String
  def to_topic
    self[0..4]
  end
end

class Position
  attr_accessor :name, :team, :signup_time

  def initialize(name, team)
    @name = name
    @team = team
    @player = nil
    @signup_time = nil
  end

  def player=(value)
    @player = value
    @signup_time = value ? Time.now : nil
  end

  def player
    @player
  end
end

class Lineup
  attr_accessor :pos_names, :positions, :player_count, :subs

  def initialize(chan, player_count, two_teams)
    @chan = chan
    @player_count = player_count
    @two_teams = two_teams
    @subs = []

    @pos_names =
    case @player_count
    when 7
      %w(gk lb rb cdm cam lw rw)
    when 3
      %w(gk lm rm)
    else
      nil
    end

    @positions = 2.times.map {|i| pos_names.map {|name| Position.new(name, i + 1) } }.flatten
  end

  def two_teams?
    @two_teams
  end

  def two_teams=(enable)
    return if enable == @two_teams

    if enable
      @chan.against = nil
    else
      @positions.each_with_index do |pos, pos_index|
        if pos.player && pos.team == 2 && @positions[pos_index - @player_count].player.nil?
          @positions[pos_index - @player_count].player = pos.player
        end

        pos.player = nil if pos.team == 2
      end
    end

    @two_teams = enable
  end
end

class User
  attr_accessor :name, :role, :dnd_end, :absent, :last_seen

  def initialize(name, role)
    @name = name
    @role = role
    @dnd_end = nil
    @absent = false
    @last_seen = nil
  end

  def op?
    @role == :op
  end

  def voice?
    @role == :voice
  end

  def dnd?
    @dnd_end && Time.now <= @dnd_end
  end
end

class Channel
  attr_accessor :name, :topic, :lineup, :against, :news, :users, :schedule, :schedule_players

  def initialize(client, name, player_count, two_teams)
    @client = client
    @name = name
    @lineup = Lineup.new(self, player_count, two_teams)
    @against = nil
    @news = nil
    @users = {}
    @schedule = nil
    @schedule_players = []
    @role_list_received = false
    deserialize(self)
  end

  def topic
    pos_texts = @lineup.positions.each_slice(@lineup.player_count).map do |pos_set|
      pos_set.collect do |pos|
        if pos.player.nil?
          "[" + StringIrc.new("#{pos.name.upcase}").to_s + "]"
        else
          "[" + StringIrc.new("#{pos.name.upcase}: #{pos.player.to_topic}").bold.to_s + "]"
        end
      end.join(' ')
    end

    text = pos_texts[0]

    against_text =
    if @lineup.two_teams?
      " - vs - " + pos_texts[1]
    else
      @against.nil? ? nil : " - vs - [" + StringIrc.new("Team: #{@against}").bold.to_s + "]"
    end

    subs_text = @lineup.subs.size > 0 ? ' | ' + StringIrc.new('[Subs: ' + @lineup.subs.map {|sub| sub.to_topic }.join(', ') + ']').bold.to_s : nil

    if @lineup.two_teams?
      text += against_text
      text += subs_text if subs_text
    else
      text += subs_text if subs_text
      text += against_text if against_text
    end

    text += " || Schedule: #{@schedule} - Avail.: #{@schedule_players.map {|player| player.to_topic }.join(', ')}" if @schedule

    text += StringIrc.new(" || #{@news}").to_s if @news

    text.strip
  end

  def poll_users
    @client.send "NAMES #{name}"
  end

  def update_users(names)
    was_op = @users[@client.nick].op?
    old_topic = topic

    names.each do |name|
      role = :normal

      case name[0]
      when '@'
        role = :op
        name = name[1..-1]
      when '+'
        role = :voice
        name = name[1..-1]
      end

      if @users[name]
        @users[name].role = role
        @users[name].absent = false
      else
        @users[name] = User.new(name, role)
      end
    end

    @role_list_received = true

    send_topic if @users[@client.nick].op? && (!was_op || old_topic != topic)
  end

  def add_user(name)
    if @users[name]
      @users[name].absent = false
    else
      @users[name] = User.new(name, :normal)
    end
  end

  def remove_user(name)
    return unless @users[name]
    @users[name].absent = true
    @users[name].last_seen = Time.now
  end

  def rename_user(old_nick, new_nick)
    return unless @users[old_nick]

    @users[old_nick].name = new_nick
    pos = @lineup.positions.find {|pos| pos.player == old_nick }

    if pos
      pos.player = new_nick
      send_topic
    end
  end

  def send_chan_message(nick, msg)
    @client.send_privmsg(@name, nick ? "#{nick}: #{msg}" : msg)
  end

  def send_topic
    if @users[@client.nick].op?
      @client.send "TOPIC #{@name} :#{topic}"
    else
      send_chan_message(nil, 'Error: I need to be operator to do my work.') if @role_list_received
    end
  end

  def send_command_list(nick)
    msg = 
    <<-eos
      Commands: !help, !<pos>, !remove [pos], !reset, !vs [team], !oneteam, !twoteams, !info <text>, !ready <server>,
      !dnd <duration<s|m|h>>, !whois <pos>, !schedule <info>, !sub, !unsub, !available, !unavailable, !highlight, !sites, !files, !ips,
      !stats, !twitter, !teamspeak, !seen. Use '/invite #{@client.nick} #yourchan' to invite me to your own channel.
    eos

    send_chan_message(nick, msg)
  end

  def handle_message(nick, type, msg)
    old_topic = topic

    case type
    when 'PRIVMSG'
      if msg =~ /^ ! (?<cmd> [^\s]+) \s? (?<params> .*) $/xi
        cmd = $~[:cmd]
        cmd.downcase! if cmd
        params = $~[:params].split(' ')

        case cmd
        when 'help', 'commands', 'cmds'
          send_command_list(nick)
        
        when *(@lineup.pos_names + %w(1 2).map {|n| @lineup.pos_names.map {|pos_name| pos_name + n } }.flatten)
          player = params[0] || nick

          wishpos = @lineup.positions.find do |pos|
            if [pos.name, pos.name + pos.team.to_s].include?(cmd)
              pos.player.nil? || pos.team == 2 || !@lineup.two_teams? || cmd == pos.name + pos.team.to_s
            end
          end

          if wishpos
            if wishpos.player || wishpos.team == 2 && !@lineup.two_teams?
              if wishpos.player && wishpos.player.to_topic == nick.to_topic
                send_chan_message(nick, 'The position is already taken by you.')
              else
                send_chan_message(nick, 'The position is already taken by another player.')
              end
            else
              oldpos = @lineup.positions.find {|pos| pos.player && pos.player.to_topic == player.to_topic }
              oldpos.player = nil if oldpos
              wishpos.player = player
            end
          else
            send_chan_message(nick, 'Position not found.')
          end

        when 'remove', 'delete'
          pos = nil
          pos_name_or_player = params[0]

          if pos_name_or_player
            pos_name_or_player.downcase!
            pos = @lineup.positions.find {|pos| [pos.name, pos.name + pos.team.to_s].include?(pos_name_or_player) }
            pos = @lineup.positions.find {|pos| pos.player && pos.player.to_topic == pos_name_or_player.to_topic } if pos.nil?
          else
            pos = @lineup.positions.find {|pos| pos.player && pos.player.to_topic == nick.to_topic }
          end

          if pos
            pos.player = nil
          else
            send_chan_message(nick, 'Position or player not found.')
          end
        
        when 'reset', 'clear', 'empty'
          @lineup.positions.each {|p| p.player = nil }
          @lineup.subs.clear
          @against = nil
        
        when 'vs', 'against', 'opponent'
          @against = params.join(' ')
          @against = nil if @against == ''
          @lineup.two_teams = false if @against
        
        when 'news', 'info'
          if @users[nick].op?
            @news = params.join(' ')
            @news = nil if @news == ''
          else
            send_chan_message(nick, 'You have to be operator to use this command')
          end

        when 'twoteams'
          @lineup.two_teams = true

        when 'oneteam'
          @lineup.two_teams = false

        when 'ready'
          text = "Go to server #{params.join(' ')}: " + @lineup.positions.collect {|pos| pos.player }.compact.join(', ') + "."
          text += " Subs: #{@lineup.subs.join(', ')}" if @lineup.subs.size > 0
          send_chan_message(nil, StringIrc.new(text).bold.to_s)

        when 'highlight'
          unsigned_users = @users.collect do |user_name, user|
            next nil if user.absent
            next nil if user.dnd?
            next nil if ['Q', @client.nick].include?(user.name)
            next nil if @lineup.positions.any? {|pos| pos.player == user.name }
            next nil if @lineup.subs.include?(user.name)
            user.name
          end.compact.join(', ')

          text = "Please sign in: #{unsigned_users}." + StringIrc.new(" Use '!dnd <duration<s|m|h>>' to remove you from this list temporarily.").bold.to_s
          send_chan_message(nil, text)

        when 'ips'
          send_chan_message(nick, "IOS Server IPs: " + (File.file?('server_ips.txt') ? File.read('server_ips.txt').split("\n").join(', ') : 'No server IPs found.'))

        when 'sites', 'websites'
          send_chan_message(nick, "IOS Websites: " + (File.file?('websites.txt') ? File.read('websites.txt').split("\n").join(', ') : 'No websites found.'))

        when 'dnd'
          if params[0].nil? || params[0] == '0'
            @users[nick].dnd_end = nil
            send_chan_message(nick, "Your dnd status has been reset.")
          elsif params.join(' ') =~ /^ (?<duration> \d+\.?\d*) \s? (?<unit> (s|m|h)) /xi
            duration = $~[:duration].to_f
            unit = ''

            case $~[:unit]
            when *%w(s second seconds)
              unit = duration == 1 ? 'second' : 'seconds'
            when *%w(m minute minutes)
              unit = duration == 1 ? 'minute' : 'minutes'
              duration *= 60
            when *%w(h hour hours)
              unit = duration == 1 ? 'hour' : 'hours'
              duration *= 60 * 60
            end

            @users[nick].dnd_end = Time.now + duration
            send_chan_message(nick, "Excluding you from highlighting for #{$~[:duration]} #{unit}. Reset with '!dnd'.")
          else
            send_chan_message(nick, "Invalid dnd syntax.")
          end

        when 'who', 'whois'
          pos = @lineup.positions.find do |pos|
            [pos.name, pos.name + pos.team.to_s].include?(params[0])
          end

          text = ''

          if pos
            if pos.player
              time_ago = (Time.now - pos.signup_time).to_time_ago
              text = "'#{pos.player.to_topic}' is '#{pos.player}' who signed up #{time_ago} ago."
            else
              text = "No player on this position."
            end
          else
              text = "Unknown position."
          end

          send_chan_message(nick, text)

        when 'stats'
          users = @client.chans.collect do |chan_name, chan|
            chan.users.collect do |user_name, user|
              if ['Q', @client.nick].include?(user.name)
                nil
              else
                user.name
              end
            end.compact
          end.flatten.uniq

          send_chan_message(nick, "I'm currently in #{@client.chans.size} channels serving #{users.size} unique users.")

        when 'twitter'
          tweets = Nokogiri::HTML(open("https://twitter.com/IOS_Insider")).css('.stream-item .content').map do |content|
            [Time.at(content.css('.stream-item-header .time span').attr('data-time').content.to_i), content.css('.tweet-text')[0].content]
          end

          tweet = tweets[0][1]
          time_ago = (Time.now - tweets[0][0]).to_time_ago

          send_chan_message(nick, "IOS-Insider #{time_ago} ago: " + StringIrc.new(tweet).bold.to_s + " (https://twitter.com/IOS_Insider)")

        when 'files', 'update', 'download'
          send_chan_message(nick, 'How to install: https://github.com/romdi/IOS || Game package: https://dl.dropboxusercontent.com/u/14644518/iosoccer.7z || Changelog: https://github.com/romdi/IOS/commits/master')

        when 'teamspeak', 'ts'
          send_chan_message(nick, 'IOS Teamspeak Server: ts3server://teamspeak.iosoccer.com')

        when 'schedule'
          @schedule = params.join(' ')

          if @schedule == ''
            @schedule = nil
            @schedule_players.clear
          end

        when 'available'
          if @schedule
            player = params[0] || nick

            if @schedule_players.any? {|schedule_player| schedule_player.to_topic == player.to_topic }
              send_chan_message(nick, "#{params[0] ? "#{player} is" : 'You are'} already in the list.")
            else
              @schedule_players << player
            end
          else
            send_chan_message(nick, "No schedule set.")
          end

        when 'unavailable'
          if @schedule
            player = params[0] || nick
            schedule_player = @schedule_players.find {|schedule_player| schedule_player.to_topic == player.to_topic }

            if schedule_player
              @schedule_players.delete(schedule_player)
            else
              send_chan_message(nick, "#{params[0] ? "#{player} is" : 'You are'} not in the list.")
            end
          else
            send_chan_message(nick, "No schedule set.")
          end

        when 'sub'
          player = params[0] || nick
          
          if @lineup.subs.any? {|sub| sub.to_topic == player.to_topic }
            send_chan_message(nick, "#{params[0] ? "#{player} is" : 'You are'} already in the list.")
          else
            @lineup.subs << player
          end

        when 'unsub'
          player = params[0] || nick
          sub = @lineup.subs.find {|sub| sub.to_topic == player.to_topic }

          if sub
            @lineup.subs.delete(sub)
          else
            send_chan_message(nick, "#{params[0] ? "#{player} is" : 'You are'} not in the list.")
          end

        when 'seen'
          player = params[0]

          if player
            msg =
            if @users[player]
              if @users[player].absent
                "was last seen #{(Time.now - @users[player].last_seen).to_time_ago} ago"
              else
                "is here right now"
              end
            else
              "hasn't been seen yet"
            end

            send_chan_message(nick, "#{player} #{msg}.")
          else
            send_chan_message(nick, 'Seen whom?')
          end
        end
      else
        URI.extract(msg, ['http', 'https']).each do |url|
          if Net::HTTP.get(URI(url)) =~ /<title>(?<title> .*?)<\/title>/xi
            title = $~[:title].force_encoding("UTF-8").strip
            title = HTMLEntities.new.decode(title)
            send_chan_message(nil, "Title: #{title}")
          end
        end
      end
    
    #:romdi!~Roman@nrbg-4dbe2fee.pool.mediaWays.net TOPIC #ios.mix :[GK: Hunki] [Lfgdfgdfgdgdf
    when 'TOPIC'
      old_topic = msg

    #:Kaim!~Kaim@62.43.91.162.dyn.user.ono.com JOIN #ios.mix
    when 'JOIN'
      add_user(nick)
      send_command_list(nil) if nick == @client.nick

    #:romdi!~Roman@nrbg-4dbe2fee.pool.mediaWays.net PART #ios.foo :Leaving
    when 'PART'
      remove_user(nick)

    #:romdi!~Roman@nrbg-4dbe2fee.pool.mediaWays.net KICK #ios.test IOSBot :IOSBot
    when 'KICK'
      @client.chans.delete(@name) if msg =~ /^ #{@client.nick} \s/xi

    end

    send_topic if topic != old_topic
  end
end

# The irc class, which talks to the server and holds the main event loop
class IRCClient
  FLOOD_CHECK_MSG = 'FLOODCHECK'

  attr_accessor :nick, :ident_username, :ident_realname, :server, :port, :chans, :logger, :bytes_sent

  def initialize(config)
    init_logger

    @server = config['server']
    @port = config['port']
    @nick = config['nickname']
    @ident_username = config['ident']['username']
    @ident_realname = config['ident']['realname']
    @auth_name = config['auth']['name']
    @auth_password = config['auth']['password']
    @bytes_sent = 0
    @flood_checking = false
    @msg_queue = []
    @authed = false

    @chans = {}

    config['channels'].each do |chan_config|
      @chans[chan_config['name']] = Channel.new(self, chan_config['name'], chan_config['players'], chan_config['twoteams'])
    end
  end

  def init_logger
    dir = File.join(File.dirname(__FILE__), 'logs')

    unless File.directory?(dir)
      FileUtils.mkdir_p(dir)
    end

    file = File.open(File.join(dir, 'log.log'), 'a')
    @logger = Logger.new(file, 'daily')
    @logger.level = Logger::DEBUG
  end

  def log(msg)
    puts Time.now.strftime("%d/%m/%Y %H:%M:%S: #{msg.strip}")
    logger.info msg.strip
  end

  def send_instantly(msg)
    @bytes_sent += msg.bytes.size + 2
    log "--> #{msg}"
    @irc.send "#{msg}\r\n", 0
  end

  def send_queued
    new_queue = @msg_queue.dup
    @msg_queue.clear
    new_queue.each {|msg| send(msg) }
  end

  def send_privmsg(target, unchecked_msg)
    extra_prepend = ":#{@nick}!~#{@ident_username}@#{@auth_name}.users.quakenet.org "
    prepend = "PRIVMSG #{target} :"
    msgs_bytes = [[]]
    index = 0

    unchecked_msg.split(' ').each do |word|
      word = ' ' + word if msgs_bytes[index].size > 0

      if extra_prepend.bytes.size + prepend.bytes.size + msgs_bytes[index].size + word.bytes.size > 510
        index += 1
        msgs_bytes[index] = word.bytes
      else
        msgs_bytes[index] += word.bytes
      end
    end

    msgs_bytes.each do |msg_bytes|
      msg = prepend + msg_bytes.pack('C*').force_encoding('UTF-8')
      send(msg)
    end
  end

  def send(msg, high_priority = false)
    if @flood_checking || @bytes_sent + msg.bytes.size + 2 > 1024 - FLOOD_CHECK_MSG.length - 3
      log('*QUEUING MESSAGE DURING FLOOD CHECK*')

      if high_priority
        @msg_queue.unshift(msg)
      else
        @msg_queue << msg
      end

      unless @flood_checking
        @flood_checking = true
        send_instantly(FLOOD_CHECK_MSG)
      end
    else
      send_instantly(msg)
    end
  end

  def connect()
    # Connect to the IRC server
    @irc = TCPSocket.open(@server, @port)
    send "USER #{@ident_username} 8 * :#{@ident_realname}"
    send "NICK #{@nick}"
  end

  def handle_server_input(s)
    log "#{s}"

    case s.strip

    #:romdi!~Roman@nrbg-4d070369.pool.mediaWays.net MODE #ios.mix -vvvv Jenaira Johnny1337 kirby- KmFCK
    #:romdi!~Roman@nrbg-4d070369.pool.mediaWays.net MODE #ios.mix +vvvv Jenaira Johnny1337 kirby- KmFCK

    #when /^ : .+? \s MODE \s (?<chan> .+?) \s (?<modes> (\+|\-|o|v)+) \s (?<nicks> .+)$/xi
    #  modes = $~[:modes].scan(/(?:\+|-)(?:v|o)+/xi)
    #  nicks = $~[:nicks].split(' ')
    #  chan = @chans[$~[:chan]]
    #  nick_index = 0
    #  modes.each_with_index do |mode, mode_index|
    #    role =
    #    if mode[0] == -
    #    (mode.length - 1).times do |i|
    #      nick = nicks[mode_index + i]
    #      chan.users[nick].role = mode[0]
    #    end
    #  end
    #  $~[:modes].each_char.each_with_index do |c, i|
    #    if
    #  end
    #  @chans[$~[:chan]].poll_users

    #+/- o/v
    when /^ : [^\s]+ \s MODE \s (?<chan> [^\s]+) \s (?<modes> (\+|-|o|v)+) \s (?<nicks> .+)$/xi
      @chans[$~[:chan]].poll_users

    # invitation
    when /^ : [^\s]+ \s INVITE \s #{@nick} \s (?<chan> .+)$/xi
      chan = $~[:chan]

      unless @chans[chan]
        @chans[chan] = Channel.new(self, chan, 7, false)
        send "JOIN #{chan}"
      end

    #:servercentral.il.us.quakenet.org 332 IOSLineupBot #ios.test : vs woo || blah
    #:servercentral.il.us.quakenet.org 333 IOSLineupBot #ios.test IOSLineupBot 1373846309
    #:servercentral.il.us.quakenet.org 353 IOSLineupBot = #ios.test :IOSLineupBot +iranian24 @romdi``
    #:xs4all.nl.quakenet.org 421 IOSLineupBot sdgdsgsgsdgsdsd :Unknown command
    #:portlane.se.quakenet.org 433 * IOSLineupBot :Nickname is already in use.

    # raw modes
    when /^ : [^\s]+ \s (?<raw> \d+) (\s \*)? \s #{@nick} \s (?<msg> .+)$/xi
      case $~[:raw].to_i
      when 221 # shows my mode / ready to join
        unless @authed
          send "PRIVMSG Q@CServe.quakenet.org :AUTH #{@auth_name} #{@auth_password}"
          send "MODE #{@nick} +x"

          @chans.each do |name, chan|
            send "JOIN #{chan.name}"
          end
        end

      when 332 # topic
        $~[:msg] =~ /^ (?<chan> [^\s]+) \s : (?<topic> .*) $/xi
        @chans[$~[:chan]].send_topic if ($~[:topic] != @chans[$~[:chan]].topic)

      when 333 # topic time
        # do nothing

      when 353 # names
        $~[:msg] =~ /^ (\=|\*|\@) \s (?<chan> [^\s]+) \s :(?<nicks> .*) $/xi
        @chans[$~[:chan]].update_users($~[:nicks].split(' '))

      when 366 # end of names

      when 421 # unknown command
        @bytes_sent = 0
        @flood_checking = false
        send_queued

      when 433 # nickname in use
        @nick += '`'
        send "NICK #{@nick}"
      end

    # quit
    when /^ : (?<nick> [^!]+) ! (?<ident> [^@]+) @ (?<host> [^\s]+) \s QUIT/xi
      @chans.each {|name, chan| chan.remove_user($~[:nick]) }

    # nick change
    when /^ : (?<nick> [^!]+) ! (?<ident> [^@]+) @ (?<host> [^\s]+) \s NICK \s : (?<new_nick> .+) $/xi
      @chans.each {|name, chan| chan.rename_user($~[:nick], $~[:new_nick]) }

    when /^PING :(.+)$/i
      log "[ Server ping ]"
      send "PONG :#{$1}", true
   
    when /^:([^!]+)!([^@]+)@([^\s]+)\sPRIVMSG\s.+\s:[\001]PING (.+)[\001]$/i
      log "[ CTCP PING from #{$1}!#{$2}@#{$3} ]"
      send "NOTICE #{$1} :\001PING #{$4}\001"
    
    when /^:([^!]+)!([^@]+)@([^\s]+)\sPRIVMSG\s.+\s:[\001]VERSION[\001]$/i
      log "[ CTCP VERSION from #{$1}!#{$2}@#{$3} ]"
      send "NOTICE #{$1} :\001VERSION IOS BOT v0.0\001"

    # privmsg, topic, join, part, kick

    when /^ : (?<nick> [^!]+) ! (?<ident> [^@]+) @ (?<host> [^\s]+) \s (?<type> [^\s]+) \s (?<chan> [^\s$]+) \s? :? (?<msg> .*)$/xi
      if @chans[$~[:chan]]
        @chans[$~[:chan]].handle_message($~[:nick], $~[:type], $~[:msg])
      end
    end
  end

  def main_loop
    # Just keep on truckin' until we disconnect
    while true
      readable, writable, error = IO.select([@irc, $stdin], nil, nil, nil)

      readable.each do |s|
        if s == $stdin
          return if $stdin.eof
          s = $stdin.gets
          send s
        elsif s == @irc
          return if @irc.eof
          s = @irc.gets
          handle_server_input(s)
        end
      end
    end
  end

  def self.start
    # The main program
    # If we get an exception, then print it out and keep going (we do NOT want
    # to disconnect unexpectedly!)

    config = YAML.load(File.read('config.yml'))

    $irc = IRCClient.new(config)
    $irc.connect
    begin
      $irc.main_loop
    rescue Interrupt
    rescue Exception => detail
      puts detail.message()
      print detail.backtrace.join("\n")
      retry
    end
  end
end

def deserialize(chan)
  return unless $data
  chan_data = $data[chan.name]
  return unless chan_data
  chan.against = chan_data['against']
  chan.news = chan_data['news']
  chan.schedule = chan_data['schedule']
  chan.schedule_players = chan_data['schedule_players']
  chan.lineup.positions.each_with_index {|pos, pos_index| pos.player = chan_data['positions'][pos_index] }
  chan.lineup.subs = chan_data['subs']
  chan_data['users'].each do |user_data|
    user = User.new(user_data['name'], user_data['role'])
    user.absent = true
    user.dnd_end = user_data['dnd_end']
    user.last_seen = user_data['last_seen']
    chan.users[user.name] = user
  end
end

def serialize
  return unless $irc && $irc.chans

  data = {}

  $irc.chans.each_value do |chan|
    chan_data = {}
    chan_data['against'] = chan.against
    chan_data['news'] = chan.news
    chan_data['schedule'] = chan.schedule
    chan_data['schedule_players'] = chan.schedule_players
    chan_data['positions'] = chan.lineup.positions.collect {|pos| pos.player }
    chan_data['subs'] = chan.lineup.subs
    chan_data['users'] = []
    chan.users.each_value do |user|
      user.last_seen = Time.now unless user.absent
      user_data = {}
      user_data['name'] = user.name
      user_data['role'] = user.role
      user_data['dnd_end'] = user.dnd_end
      user_data['last_seen'] = user.last_seen
      chan_data['users'] << user_data
    end

    data[chan.name] = chan_data
  end

  File.open('serialize.yml', 'w') {|file| file.write(YAML.dump(data)) }
end

at_exit do
  serialize
end

$data = YAML.load(File.read('serialize.yml')) if File.file?('serialize.yml')

IRCClient.start