requestLib = require 'request'
url = require 'url'
path = require 'path'
os = require 'os'
chai = require 'chai'
gavel = require 'gavel'
async = require 'async'
clone = require 'clone'
{Pitboss} = require 'pitboss-ng'

flattenHeaders = require './flatten-headers'
addHooks = require './add-hooks'
sortTransactions = require './sort-transactions'
packageData = require './../package.json'
logger = require './logger'


# use "lib" folder, because pitboss-ng does not support "coffee-script:register"
# out of the box now
sandboxedLogLibraryPath = '../../../lib/hooks-log-sandboxed'

class TransactionRunner
  constructor: (@configuration) ->
    @logs = []
    @hookStash = {}
    @error = null
    @hookHandlerError = null

  config: (config) ->
    @configuration = config
    @multiBlueprint = Object.keys(@configuration.data).length > 1

  run: (transactions, callback) ->
    logger.verbose('Sorting HTTP transactions')
    transactions = if @configuration.options['sorted'] then sortTransactions(transactions) else transactions

    logger.verbose('Configuring HTTP transactions')
    async.mapSeries transactions, @configureTransaction.bind(@), (err, results) =>
      transactions = results

      # Remainings of functional approach, probs to be eradicated
      logger.verbose('Reading hook files and registering hooks')
      addHooks @, transactions, (addHooksError) =>
        return callback addHooksError if addHooksError

        logger.verbose('Executing HTTP transactions')
        @executeAllTransactions(transactions, @hooks, callback)

  executeAllTransactions: (transactions, hooks, callback) ->
    # Warning: Following lines is "differently" performed by 'addHooks'
    # in TransactionRunner.run call. Because addHooks creates hooks.transactions
    # as an object `{}` with transaction.name keys and value is every
    # transaction, we do not fill transactions from executeAllTransactions here.
    # Transactions is supposed to be an Array here!
    unless hooks.transactions
      hooks.transactions = {}
      for transaction in transactions
        hooks.transactions[transaction.name] = transaction
    # /end warning

    return callback(@hookHandlerError) if @hookHandlerError

    logger.verbose('Running \'beforeAll\' hooks')
    @runHooksForData hooks.beforeAllHooks, transactions, true, =>
      return callback(@hookHandlerError) if @hookHandlerError

      # Iterate over transactions' transaction
      # Because async changes the way referencing of properties work,
      # we need to work with indexes (keys) here, no other way of access.
      async.timesSeries transactions.length, (transactionIndex, iterationCallback) =>
        transaction = transactions[transactionIndex]
        logger.verbose("Processing transaction ##{transactionIndex + 1}:", transaction.name)

        logger.verbose('Running \'beforeEach\' hooks')
        @runHooksForData hooks.beforeEachHooks, transaction, false, =>
          return iterationCallback(@hookHandlerError) if @hookHandlerError

          logger.verbose('Running \'before\' hooks')
          @runHooksForData hooks.beforeHooks[transaction.name], transaction, false, =>
            return iterationCallback(@hookHandlerError) if @hookHandlerError

            # This method:
            # - skips and fails based on hooks or options
            # - executes a request
            # - recieves a response
            # - runs beforeEachValidation hooks
            # - runs beforeValidation hooks
            # - runs Gavel validation
            @executeTransaction transaction, hooks, =>
              return iterationCallback(@hookHandlerError) if @hookHandlerError

              logger.verbose('Running \'afterEach\' hooks')
              @runHooksForData hooks.afterEachHooks, transaction, false, =>
                return iterationCallback(@hookHandlerError) if @hookHandlerError

                logger.verbose('Running \'after\' hooks')
                @runHooksForData hooks.afterHooks[transaction.name], transaction, false, =>
                  return iterationCallback(@hookHandlerError) if @hookHandlerError

                  logger.debug("Evaluating results of transaction execution ##{transactionIndex + 1}:", transaction.name)
                  @emitResult transaction, iterationCallback

      , (iterationError) =>
        return callback(iterationError) if iterationError

        logger.verbose('Running \'afterAll\' hooks')
        @runHooksForData hooks.afterAllHooks, transactions, true, =>
          return callback(@hookHandlerError) if @hookHandlerError
          callback()

  # The 'data' argument can be 'transactions' array or 'transaction' object
  runHooksForData: (hooks, data, legacy = false, callback) ->
    if hooks? and Array.isArray hooks
      logger.debug 'Running hooks...'

      runHookWithData = (hookFnIndex, runHookCallback) =>
        hookFn = hooks[hookFnIndex]
        try
          if legacy
            # Legacy mode is only for running beforeAll and afterAll hooks with
            # old API, i.e. callback as a first argument

            @runLegacyHook hookFn, data, (err) =>
              if err
                logger.debug('Legacy hook errored:', err)
                @emitHookError(err, data)
              runHookCallback()
          else
            @runHook hookFn, data, (err) =>
              if err
                logger.debug('Hook errored:', err)
                @emitHookError(err, data)
              runHookCallback()

        catch error
          # Beware! This is very problematic part of code. This try/catch block
          # catches also errors thrown in 'runHookCallback', i.e. in all
          # subsequent flow! Then also 'callback' is called twice and
          # all the flow can be executed twice. We need to reimplement this.
          if error instanceof chai.AssertionError
            transactions = if Array.isArray(data) then data else [data]
            @failTransaction(transaction, "Failed assertion in hooks: #{error.message}") for transaction in transactions
          else
            logger.debug('Hook errored:', error)
            @emitHookError(error, data)

          runHookCallback()

      async.timesSeries hooks.length, runHookWithData, ->
        callback()

    else
      callback()

  # The 'data' argument can be 'transactions' array or 'transaction' object.
  #
  # If it's 'transactions', it is treated as single 'transaction' anyway in this
  # function. That probably isn't correct and should be fixed eventually
  # (beware, tests count with the current behavior).
  emitHookError: (error, data) ->
    error = new Error(error) unless error instanceof Error
    test = @createTest(data)
    test.request = data.request
    @emitError(error, test)

  sandboxedHookResultsHandler: (err, data, results = {}, callback) ->
    return callback err if err
    # reference to `transaction` gets lost here if whole object is assigned
    # this is workaround how to copy properties - clone doesn't work either
    for key, value of results.data or {}
      data[key] = value
    @hookStash = results.stash

    @logs ?= []
    for log in results.logs or []
      @logs.push log
    callback()
    return

  sandboxedWrappedCode: (hookCode) ->
    return """
      // run the hook
      var log = _log.bind(null, _logs);

      var _func = #{hookCode};
      _func(_data);

      // setup the return object
      var output = {};
      output["data"] = _data;
      output["stash"] = stash;
      output["logs"] = _logs;
      output;
    """

  runSandboxedHookFromString: (hookString, data, callback) ->
    wrappedCode = @sandboxedWrappedCode hookString

    sandbox = new Pitboss(wrappedCode, {
      timeout: 500
    })

    sandbox.run
      context:
        '_data': data
        '_logs': []
        'stash': @hookStash
      libraries:
        '_log': sandboxedLogLibraryPath
    , (err, result = {}) =>
      sandbox.kill()
      @sandboxedHookResultsHandler err, data, result, callback

  # Will be used runHook instead in next major release, see deprecation warning
  runLegacyHook: (hook, data, callback) ->
    # not sandboxed mode - hook is a function
    if typeof(hook) == 'function'
      if hook.length is 1
        # sync api
        logger.warn('''\
          DEPRECATION WARNING!

          You are using only one argument for the `beforeAll` or `afterAll` hook function.
          One argument hook functions will be treated as synchronous in the near future.
          To keep the async behaviour, just define hook function with two parameters.

          Interface of the hooks functions will be unified soon across all hook functions:

           - `beforeAll` and `afterAll` hooks will support sync API depending on number of arguments
           - Signatures of callbacks of all hooks will be the same
           - First passed argument will be a `transactions` object
           - Second passed argument will be a optional callback function for async
           - `transactions` object in `hooks` module object will be removed
           - Manipulation with transaction data will have to be performed on the first function argument
        ''')

        # DEPRECATION WARNING
        # this will not be supported in future hook function will be called with
        # data synchronously and callback will be called immediatelly and not
        # passed as a second argument
        hook callback

      else if hook.length is 2
        # async api
        hook data, ->
          callback()

    # sandboxed mode - hook is a string - only sync API
    if typeof(hook) == 'string'
      @runSandboxedHookFromString hook, data, callback

  runHook: (hook, data, callback) ->
    # not sandboxed mode - hook is a function
    if typeof(hook) == 'function'
      if hook.length is 1
        # sync api
        hook data
        callback()
      else if hook.length is 2
        # async api
        hook data, ->
          callback()

    # sandboxed mode - hook is a string - only sync API
    if typeof(hook) == 'string'
      @runSandboxedHookFromString hook, data, callback

  configureTransaction: (transaction, callback) =>
    configuration = @configuration

    {origin, request, response} = transaction
    mediaType = configuration.data[origin.filename]?.mediaType or 'text/vnd.apiblueprint'

    # Parse the server URL (just once, caching it in @parsedUrl)
    @parsedUrl ?= @parseServerUrl(configuration.server)
    fullPath = @getFullPath(@parsedUrl.path, request.uri)

    flatHeaders = flattenHeaders(request['headers'])

    # Add Dredd User-Agent (if no User-Agent is already present)
    if not flatHeaders['User-Agent']
      system = os.type() + ' ' + os.release() + '; ' + os.arch()
      flatHeaders['User-Agent'] = "Dredd/" + \
        packageData.version + " (" + system + ")"

    # Parse and add headers from the config to the transaction
    if configuration.options.header.length > 0
      for header in configuration.options.header
        splitIndex = header.indexOf(':')
        headerKey = header.substring(0, splitIndex)
        headerValue = header.substring(splitIndex + 1)
        flatHeaders[headerKey] = headerValue
    request['headers'] = flatHeaders

    # The data models as used here must conform to Gavel.js
    # as defined in `http-response.coffee`
    expected =
      headers: flattenHeaders response['headers']
      body: response['body']
      statusCode: response['status']
    expected['bodySchema'] = response['schema'] if response['schema']

    # Backward compatible transaction name hack. Transaction names will be
    # replaced by Canonical Transaction Paths: https://github.com/apiaryio/dredd/issues/227
    unless @multiBlueprint
      transaction.name = transaction.name.replace("#{transaction.origin.apiName} > ", "")

    # Transaction skipping (can be modified in hooks). If the input format
    # is Swagger, non-2xx transactions should be skipped by default.
    skip = false
    if mediaType.indexOf('swagger') isnt -1
      status = parseInt(response.status, 10)
      if status < 200 or status >= 300
        skip = true

    configuredTransaction =
      name: transaction.name
      id: request.method + ' ' + request.uri
      host: @parsedUrl.hostname
      port: @parsedUrl.port
      request: request
      expected: expected
      origin: origin
      fullPath: fullPath
      protocol: @parsedUrl.protocol
      skip: skip

    return callback(null, configuredTransaction)

  parseServerUrl: (serverUrl) ->
    unless serverUrl.match(/^https?:\/\//i)
      # Protocol is missing. Remove any : or / at the beginning of the URL
      # and prepend the URL with 'http://' (assumed as default fallback).
      serverUrl = 'http://' + serverUrl.replace(/^[:\/]*/, '')
    url.parse(serverUrl)

  getFullPath: (serverPath, requestPath) ->
    return requestPath if serverPath is '/'
    return serverPath unless requestPath

    # Join two paths
    #
    # How:
    # Removes all slashes from the beginning and from the end of each segment.
    # Then joins them together with a single slash. Then prepends the whole
    # string with a single slash.
    #
    # Why:
    # Note that 'path.join' won't work on Windows and 'url.resolve' can have
    # undesirable behavior depending on slashes.
    # See also https://github.com/joyent/node/issues/2216
    segments = [serverPath, requestPath]
    segments = (segment.replace(/^\/|\/$/g, '') for segment in segments)
    # Keep trailing slash at the end if specified in requestPath
    # and if requestPath isn't only '/'
    trailingSlash = if requestPath isnt '/' and requestPath.slice(-1) is '/' then '/' else ''
    return '/' + segments.join('/') + trailingSlash

  # Factory for 'transaction.test' object creation
  createTest: (transaction) ->
    return {
      status: ''
      title: transaction.id
      message: transaction.name
      origin: transaction.origin
      startedAt: transaction.startedAt
    }

  # Marks the transaction as failed and makes sure everything in the transaction
  # object is set accordingly. Typically this would be invoked when transaction
  # runner decides to force a transaction to behave as failed.
  failTransaction: (transaction, reason) ->
    transaction.fail = true

    @ensureTransactionResultsGeneralSection(transaction)
    transaction.results.general.results.push({severity: 'error', message: reason}) if reason

    transaction.test ?= @createTest(transaction)
    transaction.test.status = 'fail'
    transaction.test.message = reason if reason
    transaction.test.results ?= transaction.results

  # Marks the transaction as skipped and makes sure everything in the transaction
  # object is set accordingly.
  skipTransaction: (transaction, reason) ->
    transaction.skip = true

    @ensureTransactionResultsGeneralSection(transaction)
    transaction.results.general.results.push({severity: 'warning', message: reason}) if reason

    transaction.test ?= @createTest(transaction)
    transaction.test.status = 'skip'
    transaction.test.message = reason if reason
    transaction.test.results ?= transaction.results

  # Ensures that given transaction object has 'results' with 'general' section
  # where custom Gavel-like errors or warnings can be inserted.
  ensureTransactionResultsGeneralSection: (transaction) ->
    transaction.results ?= {}
    transaction.results.general ?= {}
    transaction.results.general.results ?= []

  # Inspects given transaction and emits 'test *' events with 'transaction.test'
  # according to the test's status
  emitResult: (transaction, callback) ->
    if @error or not transaction.test
      logger.debug('No emission of test data to reporters', @error, transaction.test)
      @error = null # reset the error indicator
      return callback()

    if transaction.skip
      logger.debug('Emitting to reporters: test skip')
      @configuration.emitter.emit('test skip', transaction.test, -> )
      return callback()

    if transaction.test.valid
      if transaction.fail
        @failTransaction(transaction, "Failed in after hook: #{transaction.fail}")
        logger.debug('Emitting to reporters: test fail')
        @configuration.emitter.emit('test fail', transaction.test, -> )
      else
        logger.debug('Emitting to reporters: test pass')
        @configuration.emitter.emit('test pass', transaction.test, -> )
      return callback()

    logger.debug('Emitting to reporters: test fail')
    @configuration.emitter.emit('test fail', transaction.test, -> )
    callback()

  # Emits 'test error' with given test data. Halts the transaction runner.
  emitError: (error, test) ->
    logger.debug('Emitting to reporters: test error')
    @configuration.emitter.emit('test error', error, test, -> )

    # Record the error to halt the transaction runner. Do not overwrite
    # the first recorded error if more of them occured.
    @error = @error or error

  getRequestOptionsFromTransaction: (transaction) ->
    urlObject =
      protocol: transaction.protocol
      hostname: transaction.host
      port: transaction.port

    return {
      uri: url.format(urlObject) + transaction.fullPath
      method: transaction.request.method
      headers: transaction.request.headers
      body: transaction.request.body
    }

  # Add length of body if no Content-Length present
  setContentLength: (transaction) ->
    caseInsensitiveRequestHeadersMap = {}
    for key, value of transaction.request.headers
      caseInsensitiveRequestHeadersMap[key.toLowerCase()] = key

    if not caseInsensitiveRequestHeadersMap['content-length'] and transaction.request['body'] != ''
      logger.verbose('Calculating Content-Length of the request body')
      transaction.request.headers['Content-Length'] = Buffer.byteLength(transaction.request['body'], 'utf8')

  # This is actually doing more some pre-flight and conditional skipping of
  # the transcation based on the configuration or hooks. TODO rename
  executeTransaction: (transaction, hooks, callback) =>
    [callback, hooks] = [hooks, undefined] unless callback

    # Doing here instead of in configureTransaction, because request body can
    # be edited in the 'before' hook
    @setContentLength(transaction)

    # number in miliseconds (UNIX-like timestamp * 1000 precision)
    transaction.startedAt = Date.now()

    test = @createTest(transaction)
    logger.debug('Emitting to reporters: test start')
    @configuration.emitter.emit('test start', test, -> )

    @ensureTransactionResultsGeneralSection(transaction)

    if transaction.skip
      logger.verbose('HTTP transaction was marked in hooks as to be skipped. Skipping')
      transaction.test = test
      @skipTransaction(transaction, 'Skipped in before hook')
      return callback()

    else if transaction.fail
      logger.verbose('HTTP transaction was marked in hooks as to be failed. Reporting as failed')
      transaction.test = test
      @failTransaction(transaction, "Failed in before hook: #{transaction.fail}")
      return callback()

    else if @configuration.options['dry-run']
      logger.info('Dry run. Not performing HTTP request')
      transaction.test = test
      @skipTransaction(transaction)
      return callback()

    else if @configuration.options.names
      logger.info(transaction.name)
      transaction.test = test
      @skipTransaction(transaction)
      return callback()

    else if @configuration.options.method.length > 0 and not (transaction.request.method in @configuration.options.method)
      logger.info("""\
        Only #{(m.toUpperCase() for m in @configuration.options.method).join(', ')}\
        requests are set to be executed. \
        Not performing HTTP #{transaction.request.method.toUpperCase()} request.\
      """)
      transaction.test = test
      @skipTransaction(transaction)
      return callback()

    else if @configuration.options.only.length > 0 and not (transaction.name in @configuration.options.only)
      logger.info("""\
        Only '#{@configuration.options.only}' transaction is set to be executed. \
        Not performing HTTP request for '#{transaction.name}'.\
      """)
      transaction.test = test
      @skipTransaction(transaction)
      return callback()

    else
      return @performRequestAndValidate(test, transaction, hooks, callback)

  # An actual HTTP request, before validation hooks triggering
  # and the response validation is invoked here
  performRequestAndValidate: (test, transaction, hooks, callback) ->
    requestOptions = @getRequestOptionsFromTransaction(transaction)

    handleRequest = (err, res, body) =>
      if err
        logger.debug('Requesting tested server errored:', err)
        test.title = transaction.id
        test.expected = transaction.expected
        test.request = transaction.request
        @emitError(err, test)
        return callback()

      logger.verbose('Handling HTTP response from tested server')

      # The data models as used here must conform to Gavel.js
      # as defined in `http-response.coffee`
      real =
        statusCode: res.statusCode
        headers: res.headers
        body: body

      transaction['real'] = real

      logger.verbose('Running \'beforeEachValidation\' hooks')
      @runHooksForData hooks?.beforeEachValidationHooks, transaction, false, () =>
        return callback(@hookHandlerError) if @hookHandlerError

        logger.verbose('Running \'beforeValidation\' hooks')
        @runHooksForData hooks?.beforeValidationHooks[transaction.name], transaction, false, () =>
          return callback(@hookHandlerError) if @hookHandlerError

          @validateTransaction test, transaction, callback


    if transaction.request['body'] and @isMultipart requestOptions
      @replaceLineFeedInBody transaction, requestOptions

    logger.verbose("""\
      About to perform #{transaction.protocol.slice(0, -1).toUpperCase()} \
      request to tested server: #{requestOptions.method} #{requestOptions.uri}
    """)
    try
      @performRequest(requestOptions, handleRequest)
    catch error
      logger.debug('Requesting tested server errored:', error)
      test.title = transaction.id
      test.expected = transaction.expected
      test.request = transaction.request
      @emitError(error, test)
      return callback()

  performRequest: (options, callback) ->
    requestLib(options, callback)

  validateTransaction: (test, transaction, callback) ->
    configuration = @configuration

    logger.verbose('Validating HTTP transaction by Gavel.js')
    logger.debug('Determining whether HTTP transaction is valid (getting boolean verdict)')
    gavel.isValid transaction.real, transaction.expected, 'response', (isValidError, isValid) ->
      if isValidError
        logger.debug('Gavel.js validation errored:', isValidError)
        @emitError(isValidError, test)

      test.title = transaction.id
      test.actual = transaction.real
      test.expected = transaction.expected
      test.request = transaction.request

      if isValid
        test.status = 'pass'
      else
        test.status = 'fail'

      logger.debug('Validating HTTP transaction (getting verbose validation result)')
      gavel.validate transaction.real, transaction.expected, 'response', (validateError, gavelResult) ->
        if not isValidError and validateError
          logger.debug('Gavel.js validation errored:', validateError)
          @emitError(validateError, test)

        # Create test message from messages of all validation errors
        message = ''
        for own sectionName, validatorOutput of gavelResult or {} when sectionName isnt 'version'
          # Section names are 'statusCode', 'headers', 'body' (and 'version', which is irrelevant)
          for gavelError in validatorOutput.results or []
            message += "#{sectionName}: #{gavelError.message}\n"
        test.message = message

        # Record raw validation output to transaction results object
        #
        # It looks like the transaction object can already contain 'results'.
        # (Needs to be prooved, the assumption is based just on previous
        # version of the code.) In that case, we want to save the new validation
        # output, but we want to keep at least the original array of Gavel errors.
        results = transaction.results or {}
        for own sectionName, rawValidatorOutput of gavelResult when sectionName isnt 'version'
          # Section names are 'statusCode', 'headers', 'body' (and 'version', which is irrelevant)
          results[sectionName] ?= {}

          # We don't want to modify the object and we want to get rid of some
          # custom Gavel.js types ('clone' will keep just plain JS objects).
          validatorOutput = clone(rawValidatorOutput)

          # If transaction already has the 'results' object, ...
          if results[sectionName].results
            # ...then take all Gavel errors it contains and add them to the array
            # of Gavel errors in the new validator output object...
            validatorOutput.results = validatorOutput.results.concat(results[sectionName].results)
          # ...and replace the original validator object with the new one.
          results[sectionName] = validatorOutput
        transaction.results = results

        # Set the validation results and the boolean verdict to the test object
        test.results = transaction.results
        test.valid = isValid

        # Propagate test object so 'after' hooks can modify it
        transaction.test = test
        return callback()

  isMultipart: (requestOptions) ->
    caseInsensitiveRequestHeaders = {}
    for key, value of requestOptions.headers
      caseInsensitiveRequestHeaders[key.toLowerCase()] = value
    caseInsensitiveRequestHeaders['content-type']?.indexOf("multipart") > -1

  replaceLineFeedInBody: (transaction, requestOptions) ->
    if transaction.request['body'].indexOf('\r\n') == -1
      transaction.request['body'] = transaction.request['body'].replace(/\n/g, '\r\n')
      transaction.request['headers']['Content-Length'] = Buffer.byteLength(transaction.request['body'], 'utf8')
      requestOptions.headers = transaction.request['headers']


module.exports = TransactionRunner
