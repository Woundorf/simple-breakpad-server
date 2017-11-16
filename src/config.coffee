nconf = require 'nconf'
nconf.formats.yaml = require 'nconf-yaml'
fs = require 'fs-promise'
os = require 'os'
path = require 'path'

SBS_HOME = path.join(os.homedir(), '.simple-breakpad-server')

nconf.file 'pwd', {
  file: path.join(process.cwd(), 'breakpad-server.yaml')
  format: nconf.formats.yaml
}
nconf.file 'user', {
  file: path.join(SBS_HOME, 'breakpad-server.yaml')
  format: nconf.formats.yaml
}
unless process.platform == 'win32'
  nconf.file 'system', {
    file: '/etc/breakpad-server.yaml'
    format: nconf.formats.yaml
  }

nconf.argv()
nconf.env()

nconf.defaults
  baseUrl: '/'
  serverName: 'Breakpad Server'
  network:
    http:
      enabled: true
      port: 1127
    https:
      enabled: false
      port: 1128
      pfx: '/dev/null'
      pfxPassphrase: null
  database:
    host: 'localhost'
    dialect: 'sqlite'
    storage: path.join(SBS_HOME, 'database.sqlite')
    logging: no
  auth:
    enabled: false
  crashreports:
    order: ['upload_file_minidump', 'product', 'version', 'ip', 'created']
    customFields:
      files: []
      params: []
      plainParams: []
  symbols:
    order: ['os', 'name', 'arch', 'code', 'created' ]
    customFields:
      params: []
      plainParams: []
  dataDir: SBS_HOME

# Converts an array of single strings or json entries to an standarized file definition json like { name: 'comments', downloadAs: '{{id}}.txt' }
normalizeFileList = (files) ->
  return files.map (element) ->
    normalized = {}
    normalized.name = element if typeof element is 'string'
    normalized.name = element.name if typeof element.name is 'string'
    throw new Error 'Impossible to normalize file entry, name is undefined' if not normalized.name
    if typeof element.downloadAs is 'string'
      normalized.downloadAs = element.downloadAs
    else
      normalized.downloadAs = normalized.name + '.{{id}}.bin'
    return normalized

# Add default elements if they don't exist on the settings path with list.
combineConfigList = (path, defaults, comparator) ->
  comparator = comparator || (element) -> return element if element == this # Default == operator
  result = nconf.get(path)
  result.reverse()
  defaults.map (element) ->
    result.push(element) if not result.find(comparator, element)    
  result.reverse()
  nconf.set(path, result)

# Adds the default elements. Precondition: configuration and defaults must be normalized file lists
combineConfigFileList = (path, defaults) ->
  comparator = comparator || (element) -> return element if element.name == this.name
  return combineConfigList path, defaults, comparator

# Normalize given file lists
nconf.set 'crashreports:customFields:files', normalizeFileList(nconf.get('crashreports:customFields:files'))

# Add internal application fields to custom fields
combineConfigFileList 'crashreports:customFields:files', normalizeFileList([{name: 'upload_file_minidump', downloadAs: '{{id}}.dmp'}])
combineConfigList 'crashreports:customFields:params', ['product', 'version', 'os', 'arch', 'reason']
combineConfigList 'crashreports:customFields:plainParams', ['ip', 'signature', 'address']

combineConfigList 'symbols:customFields:params', []
combineConfigList 'symbols:customFields:plainParams', []

nconf.getSymbolsPath = -> path.join(nconf.get('dataDir'), 'symbols')

fs.mkdirsSync(nconf.getSymbolsPath())

module.exports = nconf
