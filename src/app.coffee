config = require './config'
moment = require 'moment'
bodyParser = require 'body-parser'
methodOverride = require('method-override')
path = require 'path'
express = require 'express'
expressSession = require 'express-session'
exphbs = require 'express-handlebars'
handlebars = require('handlebars')
hbsPaginate = require 'handlebars-paginate'
paginate = require 'express-paginate'
Crashreport = require './model/crashreport'
Symfile = require './model/symfile'
db = require './model/db'
titleCase = require 'title-case'
busboy = require 'connect-busboy'
Sequelize = require 'sequelize'
crypto = require 'crypto'
passport = require 'passport'
passportLocal = require 'passport-local'
https = require 'https'
http = require 'http'
fs = require 'fs'

crashreportToApiJson = (crashreport) ->
  json = crashreport.toJSON()

  for k,v of json
    if Buffer.isBuffer(json[k])
      json[k] = "/crashreports/#{json.id}/files/#{k}"

  json

crashreportToViewJson = (report) ->
  hidden = ['id', 'updated_at']
  fields =
    id: report.id
    props: new Map()

  unorderedProps = {}

  for name, value of Crashreport.attributes
    if value.type instanceof Sequelize.BLOB
      unorderedProps[name] = { path: "/crashreports/#{report.id}/files/#{name}" }
      config.get("crashreports:customFields:files").find (element) ->
        if element.name == name
          if element.preview
            unorderedProps[name]['preview'] = report[name] if report[name]
          return true

  json = report.toJSON()
  for k,v of json
    if k in hidden
      # pass
    else if Buffer.isBuffer(json[k])
      # already handled
    else if k == 'created_at'
      # change the name of this key for display purposes
      unorderedProps['created'] = moment(v).fromNow()
    else if v instanceof Date
      unorderedProps[k] = moment(v).fromNow()
    else if v isnt null && typeof v == 'object'
      unorderedProps[k] = v.value
    else
      unorderedProps[k] = if v? then v else 'not present'

  # Sorting
  sortable = []
  for key of unorderedProps
    if !unorderedProps.hasOwnProperty(key)
      continue
    sortable.push(key)
  order = config.get('crashreports:order') || []
  sortable.sort (a, b) ->
    return order.indexOf(a) - order.indexOf(b)
  sortable.map (key) ->
    fields.props.set(key, unorderedProps[key])

  return fields

symfileToViewJson = (symfile) ->
  hidden = ['id', 'updated_at', 'contents']
  fields =
    id: symfile.id
    contents: symfile.contents
    props: new Map()

  unorderedProps = {}
  json = symfile.toJSON()

  for k,v of json
    if k in hidden
      # pass
    else if k == 'created_at'
      # change the name of this key for display purposes
      unorderedProps['created'] = moment(v).fromNow()
    else if v instanceof Date
      unorderedProps[k] = moment(v).fromNow()
    else if v isnt null && typeof v == 'object'
      unorderedProps[k] = v.value
    else
      unorderedProps[k] = if v? then v else 'not present'

  # Sorting
  sortable = []
  for key of unorderedProps
    if !unorderedProps.hasOwnProperty(key)
      continue
    sortable.push(key)
  order = config.get('symbols:order') || []
  sortable.sort (a, b) ->
    return order.indexOf(a) - order.indexOf(b)
  sortable.map (key) ->
    fields.props.set(key, unorderedProps[key])

  return fields

# simple function to check if user is logged in
isLoggedIn = (req, res, next) ->
  return next() if !config.get('auth:enabled') || req.isAuthenticated()
  res.redirect("/login")

# initialization: init db and write all symfiles to disk
db.sync()
  .then ->
    Symfile.saveAllToDisk().then(run)
  .catch (err) ->
    console.error err.stack
    process.exit 1

run = ->
  app = express()
  breakpad = express()

  eachInMap = (context, options) ->
    if !options
      throw new Exception('Must pass iterator to #each')
    fn = options.fn
    inverse = options.inverse
    ret = ''
    data = undefined
    if options.data
      data = handlebars.createFrame(options.data)

    if context and typeof context == 'object'
      i = 0
      context.forEach (value, key) ->
        if data
          data.key = key
        ret = ret + fn(value, data: data)
        i++
    if i == 0
      ret = inverse(this)
    ret

  hbs = exphbs.create
    defaultLayout: 'main'
    partialsDir: path.resolve(__dirname, '..', 'views')
    layoutsDir: path.resolve(__dirname, '..', 'views', 'layouts')
    helpers:
      paginate: hbsPaginate
      reportUrl: (id) -> "/crashreports/#{id}"
      symfileUrl: (id) -> "/symfiles/#{id}"
      titleCase: titleCase
      eachInMap: eachInMap


  breakpad.set 'json spaces', 2
  breakpad.set 'views', path.resolve(__dirname, '..', 'views')
  breakpad.engine('handlebars', hbs.engine)
  breakpad.set 'view engine', 'handlebars'
  breakpad.use bodyParser.json()
  breakpad.use bodyParser.urlencoded({extended: true})
  breakpad.use methodOverride()

  baseUrl = config.get('baseUrl')
  serverName = config.get('serverName')

  app.use baseUrl, breakpad

  bsStatic = path.resolve(__dirname, '..', 'node_modules/bootstrap/dist')
  breakpad.use '/assets', express.static(bsStatic)
  cssDirectory = path.resolve(__dirname, '..', 'views', 'css')
  breakpad.use '/css', express.static(cssDirectory)

  # error handler
  app.use (err, req, res, next) ->
    if not err.message?
      console.log 'warning: error thrown without a message'

    console.trace err
    res.status(500).send "Bad things happened:<br/> #{err.message || err}"

  breakpad.use(busboy())

  # Authentication
  if config.get('auth:enabled')
    staticUser = config.get('auth:username')
    staticPassword = config.get('auth:password')
    if !staticUser || !staticPassword
      throw new Error 'Authentication enabled but username or password not configured'

    passport.use new passportLocal.Strategy (username, password, done) ->
      # TODO change this to hit a database of users
      if username != staticUser
        done null, false
      if password != staticPassword
        done null, false
      done null, user: 'this is the user object'

    passport.serializeUser (user, callback) ->
      callback null, user

    passport.deserializeUser (user, callback) ->
      callback null, user

    sessionSecret = crypto.randomBytes(64).toString('hex')
    breakpad.use expressSession(secret: sessionSecret, resave: true, saveUninitialized: true)
    breakpad.use passport.initialize()
    breakpad.use passport.session()

  breakpad.post '/crashreports', (req, res, next) ->
    Crashreport.createFromRequest req, res, (err, report) ->
      return next(err) if err?
      res.json(crashreportToApiJson(report))

  breakpad.get '/login', (req, res, next) ->
    res.render 'login',
      serverName: serverName
      layout: false

  breakpad.post '/auth', passport.authenticate("local", successRedirect:"/", failureRedirect:"/login")

  breakpad.get '/', isLoggedIn, (req, res, next) ->
    res.redirect '/crashreports'

  breakpad.use paginate.middleware(10, 50)
  breakpad.get '/crashreports', isLoggedIn, (req, res, next) ->
    limit = req.query.limit
    offset = req.offset
    page = req.query.page

    Crashreport.getAllReports limit, offset, req.query, (records, count) ->
      pageCount = Math.ceil(count / limit)
      viewReports = records.map(crashreportToViewJson)

      fields = []
      if viewReports.length
        viewReports[0].props.forEach (value, key) ->
          fields.push(key)

      res.render 'crashreport-index',
        serverName: serverName
        title: 'Crash Reports'
        crashreportsActive: yes
        records: viewReports
        fields: fields
        pagination:
          hide: pageCount <= 1
          page: page
          pageCount: pageCount

  breakpad.get '/crashreports/query', isLoggedIn, (req, res, next) ->
    Crashreport.getAllQueryParameters (params) ->
      res.render 'crashreport-query', {
        serverName: serverName
        params: params
      }

  breakpad.get '/symfiles', isLoggedIn, (req, res, next) ->
    limit = req.query.limit
    offset = req.offset
    page = req.query.page

    Symfile.getAllSymfiles limit, offset, req.query, (records, count) ->
      pageCount = Math.ceil(count / limit)
      viewSymfiles = records.map(symfileToViewJson)

      fields = []
      if viewSymfiles.length
        viewSymfiles[0].props.forEach (value, key) ->
          fields.push(key)

      res.render 'symfile-index',
        serverName: serverName
        title: 'Symfiles'
        symfilesActive: yes
        records: viewSymfiles
        fields: fields
        pagination:
          hide: pageCount <= 1
          page: page
          pageCount: pageCount
          query: req.query

  breakpad.get '/symfiles/query', isLoggedIn, (req, res, next) ->
    Symfile.getAllQueryParameters (params) ->
      res.render 'symfile-query', {
        serverName: serverName
        params: params
      }

  breakpad.get '/symfiles/:id', isLoggedIn, (req, res, next) ->
    Symfile.findFileById(req.params.id).then (symfile) ->
      if not symfile?
        return res.send 404, 'Symfile not found'

      if 'raw' of req.query
        res.set 'content-type', 'text/plain'
        res.send(symfile.contents.toString())
        res.end()
      else
        symfile = symfileToViewJson(symfile)
        res.render 'symfile-view', {
          serverName: serverName
          title: 'Symfile'
          symbolName: symfile.props.get('name')
          symfile: symfile
        }

  breakpad.get '/crashreports/:id', isLoggedIn, (req, res, next) ->
    Crashreport.findReportById(req.params.id).then (report) ->
      if not report?
        return res.send 404, 'Crash report not found'
      Crashreport.getStackTrace report, (err, stackwalk) ->
        return next err if err?
        fields = crashreportToViewJson(report).props

        res.render 'crashreport-view', {
          serverName: serverName
          title: 'Crash Report'
          stackwalk: stackwalk
          product: fields.get('product')
          version: fields.get('version')
          fields: fields
        }

  breakpad.get '/crashreports/:id/stackwalk', isLoggedIn, (req, res, next) ->
    # give the raw stackwalk
    Crashreport.findReportById(req.params.id).then (report) ->
      if not report?
        return res.send 404, 'Crash report not found'
      Crashreport.getStackTrace report, (err, stackwalk) ->
        return next err if err?
        res.set('Content-Type', 'text/plain')
        res.send(stackwalk.toString('utf8'))

  breakpad.get '/crashreports/:id/files/:filefield', isLoggedIn, (req, res, next) ->
    # download the file for the given id
    Crashreport.findReportById(req.params.id).then (crashreport) ->
      if not crashreport?
        return res.status(404).send 'Crash report not found'

      field = req.params.filefield
      contents = crashreport.get(field)

      if not Buffer.isBuffer(contents)
        return res.status(404).send 'Crash report field is not a file'

      # Find appropriate downloadAs file name
      fileDefinition = config.get("crashreports:customFields:files").find((element) -> return element if element.name == field)
      filename = fileDefinition.downloadAs.replace('{{id}}', req.params.id)

      res.setHeader('content-disposition', "attachment; filename=\"#{filename}\"")
      res.send(contents)

  breakpad.get '/api/crashreports', isLoggedIn, (req, res, next) ->
    # Query for a count of crash reports matching the requested query parameters
    # e.g. /api/crashreports?version=1.2.3
    where = {}
    for name, value of Crashreport.attributes
      unless value.type instanceof Sequelize.BLOB
        if req.query[name]
          where[name] = req.query[name]
    Crashreport.count({ where }).then (result) ->
      res.json
        count: result
    .error next


  breakpad.use(busboy())
  breakpad.post '/symfiles', (req, res, next) ->
    Symfile.createFromRequest req, res, (err, symfile) ->
      return next(err) if err?
      symfileJson = symfile.toJSON()
      delete symfileJson.contents
      res.json symfileJson

  httpEnabled = config.get('network:http:enabled')
  if httpEnabled
    port = config.get('network:http:port')
    http.createServer(app).listen(port)
    console.log "Listening HTTP on port #{port}"

  httpsEnabled = config.get('network:https:enabled')
  if httpsEnabled
    httpsPort = config.get('network:https:port')
    pfx = config.get('network:https:pfx')
    pfxPassphrase = config.get('network:https:pfxPassphrase')
    httpsOptions =
        pfx: fs.readFileSync pfx
        passphrase: pfxPassphrase
    https.createServer(httpsOptions, app).listen(httpsPort)
    console.log "Listening HTTPS on port #{httpsPort}"

