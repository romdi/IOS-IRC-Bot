IOS' IRC bot written in ruby. It's mainly used for managing line-ups in mix and private team channels.

You have to add a `config.yml` YAML configuration file to the folder you run the bot from.

Example `config.yml`:

```
---
server: 'irc.quakenet.org'
port: 6667
nickname: 'IOS-Bot'
ident:
  username: 'iosbot'
  realname: 'IOS Bot'
auth:
  name: 'authname'
  password: 'password'
channels:
  - name: '#chan1'
    players: 7
    twoteams: true
  - name: '#chan2'
    players: 3
    twoteams: true
```

Additional optional files are `server_ips.txt` for a list of game server IPs and `websites.txt` for IOS-related websites.
These files can be changed while the bot is running as they are re-read on every user request.
IPs and websites should be separated by newline characters.

The bot logs all messages to `log/log.log`.

Tested with ruby 2.0.0.
