config = require '../config'
path = require 'path'
fs = require 'fs-promise'
cache = require './cache'
minidump = require 'minidump'
Sequelize = require 'sequelize'
sequelize = require './db'
tmp = require 'tmp'
addr = require 'addr'
streamToArray = require 'stream-to-array'

symbolsPath = config.getSymbolsPath()

# custom fields should have 'files' and 'params'
customFields = config.get('crashreports:customFields') || {}

schema =
  id:
    type: Sequelize.INTEGER
    autoIncrement: yes
    primaryKey: yes

options =
  indexes: [
    { fields: ['created_at'] }
  ]

for field in customFields.files
  schema[field.name] = Sequelize.BLOB

for field in customFields.plainParams
  schema[field] = Sequelize.STRING

Crashreport = sequelize.define('crashreports', schema, options)

exclude = []

getAliasFromDbName = (dbName) ->
  alias = dbName.substring(dbName.lastIndexOf('_') + 1)
  return alias

CustomFields = []
customFields.params.map (alias) ->
  param = 'crashreport_' + alias
  customField = sequelize.define( param,
    id:
      type: Sequelize.INTEGER
      autoIncrement: yes
      primaryKey: yes
    value:
      type: Sequelize.STRING
  )
  foreignKey = alias + '_id'
  Crashreport.belongsTo(customField, foreignKey: foreignKey, as: alias)
  customField.hasMany(Crashreport, foreignKey: foreignKey, as: alias)
  CustomFields.push(customField)
  exclude.push(foreignKey)

Sequelize.sync

Crashreport.findReportById = (param) ->
  include = []

  CustomFields.map (customField) ->
    alias = getAliasFromDbName(customField.name)
    customInclude = { model: customField, as: alias }
    include.push(customInclude)

  options =
    include: include
    attributes:
      exclude: exclude
  Crashreport.findById(param, options)

Crashreport.getAllReports = (limit, offset, query, callback) ->
  include = []
  # only fetch non-blob attributes to speed up the query
  excludeWithBlob = customFields.files.map (element) -> return element.name

  CustomFields.map (customField) ->
    alias = getAliasFromDbName(customField.name)
    customInclude = { model: customField, as: alias }
    if alias of query && !!query[alias]
      customInclude['where'] =  { value: query[alias] }
    include.push(customInclude)
    excludeWithBlob.push(alias + '_id')

  findAllQuery =
    order: [['created_at', 'DESC']]
    limit: limit
    offset: offset
    attributes:
      exclude: excludeWithBlob
    include: include

  Crashreport.findAndCountAll(findAllQuery).then (q) ->
    records = q.rows
    count = q.count
    callback(records, count)

Crashreport.getAllQueryParameters = (callback) ->
  allPromises = []
  CustomFields.map((customField) ->
    allPromises.push(customField.findAll())
  )
  queryParameters = {}
  Sequelize.Promise.all(allPromises).then (results) ->
    values = []
    for i in [0...CustomFields.length]
      values = []
      for field in results[i]
        values.push(field.value)
      queryParameters[getAliasFromDbName(CustomFields[i].name)] = values

    callback(queryParameters)

Crashreport.createFromRequest = (req, res, callback) ->
  props = {}
  streamOps = []
  httpPostFields = {}

  req.busboy.on 'file', (fieldname, file, filename, encoding, mimetype) ->
    streamOps.push streamToArray(file).then((parts) ->
      buffers = []
      for i in [0 .. parts.length - 1]
        part = parts[i]
        buffers.push if part instanceof Buffer then part else new Buffer(part)

      return Buffer.concat(buffers)
    ).then (buffer) ->
      if fieldname of Crashreport.attributes
        props[fieldname] = buffer

  req.busboy.on 'field', (fieldname, val, fieldnameTruncated, valTruncated) ->
    if fieldname == 'prod'
      httpPostFields['product'] = val.toString()
    else if fieldname == 'ver'
      httpPostFields['version'] = val.toString()
    else
      httpPostFields[fieldname] = val.toString()

  req.busboy.on 'finish', ->
    Promise.all(streamOps).then ->
      if not props.hasOwnProperty('upload_file_minidump')
        res.status 400
        throw new Error 'Form must include a "upload_file_minidump" field'

      if not httpPostFields.hasOwnProperty('version')
        res.status 400
        throw new Error 'Form must include a "ver" field'

      if not httpPostFields.hasOwnProperty('product')
        res.status 400
        throw new Error 'Form must include a "prod" field'

      # Get originating request address, respecting reverse proxies (e.g. X-Forwarded-For header)
      # Fixed list of just localhost as trusted reverse-proxy, we can add a config option if needed
      # Those deletions disallow using the values from the request.
      httpPostFields['ip'] = addr(req, ['127.0.0.1', '::ffff:127.0.0.1'])
      delete httpPostFields['os']
      delete httpPostFields['arch']
      delete httpPostFields['signature']

      Crashreport.getStackTraceFromBlob props['upload_file_minidump'], (err, stackwalk) ->
        if not err
          metadata = Crashreport.getStackwalkMetadata stackwalk
          for key, value of metadata
            httpPostFields[key] = value if value

        sequelize.transaction (t) ->
          allPromises = []
          postedFieldNames = []
          CustomFields.map (customField) ->
            fieldName = getAliasFromDbName(customField.name)
            if fieldName of httpPostFields
              postedFieldNames.push(fieldName)
              allPromises.push(customField.findOrCreate({where: {value: httpPostFields[fieldName]},transaction: t}))

          for fieldName in customFields.plainParams
            if fieldName of httpPostFields
              props[fieldName] = httpPostFields[fieldName]

          Sequelize.Promise.all(allPromises).then (results) ->

            for i in [0...allPromises.length]
              if !results[i]
                continue
              customFieldId = postedFieldNames[i] + '_id'
              customField = results[i][0]
              props[customFieldId] = customField.id

            include = []
            CustomFields.map (customField) ->
              customInclude = { model: customField, as: getAliasFromDbName(customField.name) }
              include.push(customInclude)

            Crashreport.create(props, include: include, transaction: t).then (report) ->
              query =
                where: props
                include: include
                attributes:
                  exclude: exclude
                transaction: t
              Crashreport.findOne(query).then (report) ->
                callback(null, report)

    .catch (err) ->
      callback err

  req.pipe(req.busboy)

Crashreport.getStackTrace = (record, callback) ->
  return callback(null, cache.get(record.id)) if cache.has record.id
  return Crashreport.getStackTraceFromBlob record.upload_file_minidump, (err, stackwalk) ->
    cache.set record.id, stackwalk unless err?
    return callback(err, stackwalk)

Crashreport.getStackTraceFromBlob = (blob, callback) ->
  tmpfile = tmp.fileSync()
  fs.writeFile(tmpfile.name, blob).then ->
    minidump.walkStack tmpfile.name, [symbolsPath], (err, stackwalk) ->
      tmpfile.removeCallback()
      callback err, stackwalk
  .catch (err) ->
    tmpfile.removeCallback()
    callback err

# Extracts os, singature, etc. form stackwalk
Crashreport.getStackwalkMetadata = (stackwalk) ->
  metadata =
    os: null
    arch: null
    signature: null
    reason: null
    address: null

  # We expect to have the information at the beginning.
  firstLines = stackwalk.toString 'utf-8', 0, 2048
  # Matches the begining and extracts to the end. Replace is not used to replace
  firstLines.replace ///\(crashed\)\n\s+\d+\s+///, (matched, start, str) ->
    begin = start + matched.length
    metadata.signature = str.slice begin, str.indexOf('\n', begin)
  firstLines.replace ///CPU:\s+///, (matched, start, str) ->
    begin = start + matched.length
    metadata.arch = str.slice begin, str.indexOf('\n', begin)
  firstLines.replace ///Operating\ssystem:\s+///, (matched, start, str) ->
    begin = start + matched.length
    metadata.os = str.slice begin, str.indexOf('\n', begin)
  firstLines.replace ///Crash\sreason:\s+///, (matched, start, str) ->
    begin = start + matched.length
    metadata.reason = str.slice begin, str.indexOf('\n', begin)
  firstLines.replace ///Crash\saddress:\s+///, (matched, start, str) ->
    begin = start + matched.length
    metadata.address = str.slice begin, str.indexOf('\n', begin)

  return metadata

module.exports = Crashreport
