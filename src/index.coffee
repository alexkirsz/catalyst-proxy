http = require 'http'
Proxy = require './proxy'

http.globalAgent.maxSockets = Infinity

new Proxy 8080
