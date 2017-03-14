http = require('http')
url = require('url')
{assert} = require('chai')

{createServer, runDredd, runDreddWithServer, recordLogging, DEFAULT_SERVER_PORT} = require('./helpers')
logger = require('../../src/logger')
Dredd = require('../../src/dredd')


PROXY_PORT = DEFAULT_SERVER_PORT + 1
PROXY_URL = "http://127.0.0.1:#{PROXY_PORT}" # using http: even for HTTPS proxy (see 'createHttpsProxy')

SERVER_URL_HTTP = 'http://tested-api.example.com'
APIARY_API_URL_HTTP = 'http://apiary-api.example.com'
REMOTE_API_DESCRIPTION_URL_HTTP = 'http://static.example.com/example.apib'

SERVER_URL_HTTPS = 'https://tested-api.example.com'
APIARY_API_URL_HTTPS = 'https://apiary-api.example.com'
REMOTE_API_DESCRIPTION_URL_HTTPS = 'https://static.example.com/example.apib'


# Normally, tests create Dredd instance and pass it to the 'runDredd'
# helper, which captures Dredd's logging while it runs. However, in
# this case we need to capture logging also during the instantiation.
createAndRunDredd = (configuration, done) ->
  configuration.options ?= {}
  configuration.options.color = false
  configuration.options.silent = true
  configuration.options.level = 'debug'

  dredd = undefined
  recordLogging((next) ->
    dredd = new Dredd(configuration)
    next()
  , (err, args, dreddInitLogging) ->
    runDredd(dredd, (err, info) ->
      info.dreddInitLogging = dreddInitLogging if info
      done(err, info)
    )
  )


describe('Respecting HTTP Proxy Settings', ->
  proxy = undefined
  proxyReq = undefined

  beforeEach((done) ->
    server = http.createServer()

    proxyReq = {}
    server.on('request', (req, res) ->
      proxyReq.url = req.url
      proxyReq.method = req.method

      res.writeHead(200, {'Content-Type': 'text/plain'})
      res.end('OK')
    )

    proxy = server.listen(PROXY_PORT, done)
  )
  afterEach((done) ->
    proxyReq = undefined
    proxy.close(done)
  )


  # describe('When Set by dredd.yml', ->
  describe('When Set by Environment Variables', ->
    beforeEach( ->
      process.env['http_proxy'] = PROXY_URL
    )
    afterEach( ->
      delete process.env['http_proxy']
    )

    describe('Requesting Server Under Test', ->
      dreddInitLogging = undefined

      beforeEach((done) ->
        createAndRunDredd(
          server: SERVER_URL_HTTP
          options:
            path: './test/fixtures/single-get.apib'
        , (err, info) ->
          return done(err) if err
          dreddInitLogging = info.dreddInitLogging
          done()
        )
      )

      it('requests the proxy, using the original server URL as a path', ->
        assert.equal(proxyReq.method, 'GET')
        assert.equal(proxyReq.url, "#{SERVER_URL_HTTP}/machines")
      )
      it('logs the settings and mentions the source of the settings', ->
        assert.include(dreddInitLogging, "http_proxy=#{PROXY_URL}")
      )
    )

    describe('Using Apiary Reporter', ->
      dreddInitLogging = undefined

      beforeEach((done) ->
        process.env.APIARY_API_URL = APIARY_API_URL_HTTP

        createAndRunDredd(
          server: SERVER_URL_HTTP
          options:
            path: './test/fixtures/single-get.apib'
            reporter: ['apiary']
        , (err, info) ->
          return done(err) if err
          dreddInitLogging = info.dreddInitLogging
          done()
        )
      )
      afterEach( ->
        delete process.env.APIARY_API_URL
      )

      it('requests the proxy, using the original Apiary reporter API URL as a path', ->
        assert.equal(proxyReq.method, 'POST')
        assert.equal(proxyReq.url, "#{APIARY_API_URL_HTTP}/apis/public/tests/runs")
      )
      it('logs the settings and mentions the source of the settings', ->
        assert.include(dreddInitLogging, "http_proxy=#{PROXY_URL}")
      )
    )

    describe('Downloading API Description Document', ->
      dreddInitLogging = undefined

      beforeEach((done) ->
        createAndRunDredd(
          server: SERVER_URL_HTTP
          options:
            path: REMOTE_API_DESCRIPTION_URL_HTTP
        , (err, info) ->
          return done(err) if err
          dreddInitLogging = info.dreddInitLogging
          done()
        )
      )

      it('requests the proxy, using the original API description URL as a path', ->
        assert.equal(proxyReq.method, 'GET')
        assert.equal(proxyReq.url, REMOTE_API_DESCRIPTION_URL_HTTP)
      )
      it('logs the settings and mentions the source of the settings', ->
        assert.include(dreddInitLogging, "http_proxy=#{PROXY_URL}")
      )
    )
  )
)


describe('Respecting HTTPS Proxy Settings', ->
  proxy = undefined
  proxyReq = undefined

  beforeEach((done) ->
    # Uses the 'http' module, because otherwise we would need to grapple
    # with certificates in the test. Using 'http' for running the proxy
    # doesn't affect anything. The important difference is whether the
    # URLs requested by Dredd start with 'http://' or 'https://'.
    #
    # See https://en.wikipedia.org/wiki/HTTP_tunnel#HTTP_CONNECT_tunneling
    # and https://github.com/request/request#proxies
    server = http.createServer()

    proxyReq = {}
    server.on('connect', (req, socket) ->
      proxyReq.url = req.url
      proxyReq.method = req.method

      socket.write('HTTP/1.1 200 Connection Established\r\n\r\n')
      socket.end()
    )

    proxy = server.listen(PROXY_PORT, done)
  )
  afterEach((done) ->
    proxyReq = undefined
    proxy.close(done)
  )


  # describe('When Set by dredd.yml', ->
  describe('When Set by Environment Variables', ->
    beforeEach( ->
      process.env['https_proxy'] = PROXY_URL
    )
    afterEach( ->
      delete process.env['https_proxy']
    )

    describe('Requesting Server Under Test', ->
      dreddInitLogging = undefined

      beforeEach((done) ->
        createAndRunDredd(
          server: SERVER_URL_HTTPS
          options:
            path: './test/fixtures/single-get.apib'
        , (err, info) ->
          return done(err) if err
          dreddInitLogging = info.dreddInitLogging
          done()
        )
      )

      it('requests the proxy server with CONNECT', ->
        assert.equal(proxyReq.method, 'CONNECT')
      )
      it('asks the proxy to tunnel SSL connection to the original hostname', ->
        assert.equal(
          proxyReq.url,
          "#{url.parse(SERVER_URL_HTTP).hostname}:443"
        )
      )
      it('logs the settings and mentions the source of the settings', ->
        assert.include(dreddInitLogging, "https_proxy=#{PROXY_URL}")
      )
    )

    describe('Using Apiary Reporter', ->
      dreddInitLogging = undefined

      beforeEach((done) ->
        process.env.APIARY_API_URL = APIARY_API_URL_HTTPS

        createAndRunDredd(
          server: SERVER_URL_HTTPS
          options:
            path: './test/fixtures/single-get.apib'
            reporter: ['apiary']
        , (err, info) ->
          return done(err) if err
          dreddInitLogging = info.dreddInitLogging
          done()
        )
      )
      afterEach( ->
        delete process.env.APIARY_API_URL
      )

      it('requests the proxy server with CONNECT', ->
        assert.equal(proxyReq.method, 'CONNECT')
      )
      it('asks the proxy to tunnel SSL connection to the original hostname', ->
        assert.equal(
          proxyReq.url,
          "#{url.parse(APIARY_API_URL_HTTPS).hostname}:443"
        )
      )
      it('logs the settings and mentions the source of the settings', ->
        assert.include(dreddInitLogging, "https_proxy=#{PROXY_URL}")
      )
    )

    describe('Downloading API Description Document', ->
      dreddInitLogging = undefined

      beforeEach((done) ->
        createAndRunDredd(
          server: SERVER_URL_HTTPS
          options:
            path: REMOTE_API_DESCRIPTION_URL_HTTPS
        , (err, info) ->
          return done(err) if err
          dreddInitLogging = info.dreddInitLogging
          done()
        )
      )

      it('requests the proxy server with CONNECT', ->
        assert.equal(proxyReq.method, 'CONNECT')
      )
      it('asks the proxy to tunnel SSL connection to the original hostname', ->
        assert.equal(
          proxyReq.url,
          "#{url.parse(REMOTE_API_DESCRIPTION_URL_HTTPS).hostname}:443"
        )
      )
      it('logs the settings and mentions the source of the settings', ->
        assert.include(dreddInitLogging, "https_proxy=#{PROXY_URL}")
      )
    )
  )
)