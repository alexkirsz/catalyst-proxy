http = require 'http'
url = require 'url'

_ = require 'lodash'

Request = require './request'

module.exports = class Proxy
  constructor: (listenPort, listenHost, opts = {}) ->
    if typeof listenHost is 'object'
      opts = listenHost
      listenHost = undefined

    @opts = _.clone opts
    _.defaults @opts,
      maxConcurrent: 12
      partSize: 1024 * 1024 / 4
      minContentLength: 1024 * 1024

    http.createServer()
      .on('request', @request)
      .listen(listenPort, listenHost)

  _isDownloadable: (res) ->
    res.statusCode in [200, 206] and (parseInt res.headers['content-length']) >= @opts.minContentLength

  request: (clientReq, clientRes) =>
    reqOpts = url.parse clientReq.url
    reqOpts.method = clientReq.method
    reqOpts.headers = clientReq.headers
    reqOpts.agent = new http.Agent maxSockets: @opts.maxConcurrent

    # Create new request
    request = new Request reqOpts, @opts

    # Listen to connect and determine whether to stream download or not
    request.on 'connect', (res, callback) =>
      clientRes.writeHead res.statusCode, res.headers
      callback (@_isDownloadable res)

    # Pipe clientRequest to request, request to clientResponse
    clientReq.pipe request
    request.pipe clientRes

    # Start the request
    request.start()

    # Stop the request whether or not it has completed
    clientRes.on 'close', ->
      request.stop()
