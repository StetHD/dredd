{assert} = require('chai')

{createServer, runDredd, recordLogging, DEFAULT_SERVER_PORT} = require('./helpers')
logger = require('../../src/logger')
Dredd = require('../../src/dredd')


PROXY_PORT = DEFAULT_SERVER_PORT + 1
PROXY = "http://127.0.0.1:#{PROXY_PORT}"
SERVER_URL = 'http://example.com'


# TODO 'https'
['http'].forEach((protocol) ->
  describe("Respecting #{protocol.toUpperCase()} Proxy", ->
    proxy = undefined
    proxyRuntimeInfo = undefined

    beforeEach((done) ->
      proxy = createServer().listen(PROXY_PORT, (err, info) ->
        proxyRuntimeInfo = info
        done(err)
      )
    )
    afterEach((done) ->
      proxyRuntimeInfo = undefined
      proxy.close(done)
    )

    describe('When Set by Environment Variables', ->
      beforeEach( ->
        process.env["#{protocol}_proxy"] = PROXY
      )
      afterEach( ->
        delete process.env["#{protocol}_proxy"]
      )

      describe('Requesting Server Under Test', ->
        dreddInitLogging = undefined

        beforeEach((done) ->
          dredd = undefined
          recordLogging((next) ->
            dredd = new Dredd(
              server: SERVER_URL
              options:
                path: './test/fixtures/single-get.apib'
                color: false
                silent: true
                level: 'verbose'
            )
            next()
          , (err, args, logging) ->
            dreddInitLogging = logging
            runDredd(dredd, done)
          )
        )

        it('requests the proxy, using the original URL as a path', ->
          assert.deepEqual(
            proxyRuntimeInfo.requestCounts,
            {"#{SERVER_URL}/machines": 1}
          )
        )
        it('logs the settings and mentions source of the settings', ->
          assert.include(dreddInitLogging, "#{protocol}_proxy=#{PROXY}")
        )
      )

      describe('Using Apiary Reporter', ->

      )

      describe('Downloading API description document', ->

      )
    )

    describe('When Set by dredd.yml', ->

      describe('Requesting Server Under Test', ->

      )

      describe('Using Apiary Reporter', ->

      )

      describe('Downloading API description document', ->

      )
    )
  )
)