http = require 'http'
url = require 'url'
Request = require './request'

module.exports = class Proxy
  constructor: (listenPort, listenHost) ->
    @agent = new http.Agent maxSockets: Infinity

    http.createServer()
      .on('request', @request)
      .listen(listenPort, listenHost)

  request: (req, res) =>
    opts = url.parse req.url
    opts.method = req.method
    opts.headers = req.headers
    opts.agent = @agent

    request = new Request opts, req, res
