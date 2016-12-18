path = require 'path'
{Point, CompositeDisposable} = require 'atom'
{$, $$, SelectListView} = require 'atom-space-pen-views'
{repositoryForPath} = require './helpers'
fs = require 'fs-plus'
fuzzaldrin = require 'fuzzaldrin'
fuzzaldrinPlus = require 'fuzzaldrin-plus'
FileIcons = require './file-icons'

module.exports =
class FuzzyFinderView extends SelectListView
  filePaths: null
  projectRelativePaths: null
  subscriptions: null
  alternateScoring: false

  initialize: ->
    super

    @addClass('fuzzy-finder')
    @setMaxItems(10)
    @subscriptions = new CompositeDisposable

    splitLeft = => @splitOpenPath (pane) -> pane.splitLeft.bind(pane)
    splitRight = => @splitOpenPath (pane) -> pane.splitRight.bind(pane)
    splitUp = => @splitOpenPath (pane) -> pane.splitUp.bind(pane)
    splitDown = => @splitOpenPath (pane) -> pane.splitDown.bind(pane)

    atom.commands.add @element,
      'pane:split-left': splitLeft
      'pane:split-left-and-copy-active-item': splitLeft
      'pane:split-left-and-move-active-item': splitLeft
      'pane:split-right': splitRight
      'pane:split-right-and-copy-active-item': splitRight
      'pane:split-right-and-move-active-item': splitRight
      'pane:split-up': splitUp
      'pane:split-up-and-copy-active-item': splitUp
      'pane:split-up-and-move-active-item': splitUp
      'pane:split-down': splitDown
      'pane:split-down-and-copy-active-item': splitDown
      'pane:split-down-and-move-active-item': splitDown
      'fuzzy-finder:invert-confirm': =>
        @confirmInvertedSelection()

    @alternateScoring = atom.config.get 'fuzzy-finder.useAlternateScoring'
    @subscriptions.add atom.config.onDidChange 'fuzzy-finder.useAlternateScoring', ({newValue}) => @alternateScoring = newValue


  getFilterKey: ->
    'projectRelativePath'

  cancel: ->
    if atom.config.get('fuzzy-finder.preserveLastSearch')
      lastSearch = @getFilterQuery()
      super

      @filterEditorView.setText(lastSearch)
      @filterEditorView.getModel().selectAll()
    else
      super

  destroy: ->
    @cancel()
    @panel?.destroy()
    @subscriptions?.dispose()
    @subscriptions = null

  viewForItem: ({filePath, projectRelativePath, matches}) ->
    # Style matched characters in search results
    $$ ->

      highlighter = (path, matches, offsetIndex) =>
        lastIndex = 0
        matchedChars = [] # Build up a set of matched chars to be more semantic

        for matchIndex in matches
          matchIndex -= offsetIndex
          continue if matchIndex < 0 # If marking up the basename, omit path matches
          unmatched = path.substring(lastIndex, matchIndex)
          if unmatched
            @span matchedChars.join(''), class: 'character-match' if matchedChars.length
            matchedChars = []
            @text unmatched
          matchedChars.push(path[matchIndex])
          lastIndex = matchIndex + 1

        @span matchedChars.join(''), class: 'character-match' if matchedChars.length

        # Remaining characters are plain text
        @text path.substring(lastIndex)


      @li class: 'two-lines', =>
        if (repo = repositoryForPath(filePath))?
          status = repo.getCachedPathStatus(filePath)
          if repo.isStatusNew(status)
            @div class: 'status status-added icon icon-diff-added'
          else if repo.isStatusModified(status)
            @div class: 'status status-modified icon icon-diff-modified'

        typeClass = FileIcons.getService().iconClassForPath(filePath, 'fuzzy-finder') or []
        unless Array.isArray typeClass
          typeClass = typeClass?.toString().split(/\s+/g)

        fileBasename = path.basename(filePath)
        baseOffset = projectRelativePath.length - fileBasename.length

        @div class: "primary-line file icon #{typeClass.join(' ')}", 'data-name': fileBasename, 'data-path': projectRelativePath, -> highlighter(fileBasename, matches, baseOffset)
        @div class: 'secondary-line path no-icon', -> highlighter(projectRelativePath, matches, 0)

  openPath: (filePath, lineNumber, openOptions) ->
    if filePath
      atom.workspace.open(filePath, openOptions).then => @moveToLine(lineNumber)

  moveToLine: (lineNumber=-1) ->
    return unless lineNumber >= 0

    if textEditor = atom.workspace.getActiveTextEditor()
      position = new Point(lineNumber)
      textEditor.scrollToBufferPosition(position, center: true)
      textEditor.setCursorBufferPosition(position)
      textEditor.moveToFirstCharacterOfLine()

  splitOpenPath: (splitFn) ->
    {filePath} = @getSelectedItem() ? {}
    lineNumber = @getLineNumber()

    if @isQueryALineJump() and editor = atom.workspace.getActiveTextEditor()
      pane = atom.workspace.getActivePane()
      splitFn(pane)(copyActiveItem: true)
      @moveToLine(lineNumber)
    else if not filePath
      return
    else if pane = atom.workspace.getActivePane()
      splitFn(pane)()
      @openPath(filePath, lineNumber)
    else
      @openPath(filePath, lineNumber)

  populateList: ->
    if @isQueryALineJump()
      @list.empty()
      @setError('Jump to line in active editor')
    else if @alternateScoring
      @populateAlternateList()
    else
      super


  # Unfortunately  SelectListView do not allow inheritor to handle their own filtering.
  # That would be required to use external knowledge, for example: give a bonus to recent files.
  #
  # Or, in this case: test an alternate scoring algorithm.
  #
  # This is modified copy/paste from SelectListView#populateList, require jQuery!
  # Should be temporary

  populateAlternateList: ->

    return unless @items?

    filterQuery = @getFilterQuery()
    if filterQuery.length
      filteredItems = fuzzaldrinPlus.filter(@items, filterQuery, key: @getFilterKey())
    else
      filteredItems = @items

    @list.empty()
    if filteredItems.length
      @setError(null)
      displayedItems = []
      for i in [0...Math.min(filteredItems.length, @maxItems)]
        item = filteredItems[i]

        if @alternateScoring
          item.matches = fuzzaldrinPlus.match(item.projectRelativePath, filterQuery)
          item.score = fuzzaldrinPlus.score(item.projectRelativePath, filterQuery)
        else
          item.matches = fuzzaldrin.match(item.projectRelativePath, filterQuery)
          item.score = scorer.score(item.projectRelativePath, filterQuery)
        skippedTotal = 0
        for skip in item.skip
          if !item.matches.some((match) -> match >= skip.start && match < skip.end)
            skippedTotal += skip.end - skip.start
        item.score *= item.projectRelativePath.length / (item.projectRelativePath.length - skippedTotal)
        displayedItems.push(item)
      displayedItems.sort((a, b) -> b.score - a.score)
      for item in displayedItems
        itemView = $(@viewForItem(item))
        itemView.data('select-list-item', item)
        @list.append(itemView)

      @selectItemView(@list.find('li:first'))
    else
      @setError(@getEmptyMessage(@items.length, filteredItems.length))



  confirmSelection: ->
    item = @getSelectedItem()
    @confirmed(item, searchAllPanes: atom.config.get('fuzzy-finder.searchAllPanes'))

  confirmInvertedSelection: ->
    item = @getSelectedItem()
    @confirmed(item, searchAllPanes: not atom.config.get('fuzzy-finder.searchAllPanes'))

  confirmed: ({filePath}={}, openOptions) ->
    if atom.workspace.getActiveTextEditor() and @isQueryALineJump()
      lineNumber = @getLineNumber()
      @cancel()
      @moveToLine(lineNumber)
    else if not filePath
      @cancel()
    else if fs.isDirectorySync(filePath)
      @setError('Selected path is a directory')
      setTimeout((=> @setError()), 2000)
    else
      lineNumber = @getLineNumber()
      @cancel()
      @openPath(filePath, lineNumber, openOptions)

  isQueryALineJump: ->
    query = @filterEditorView.getModel().getText()
    colon = query.indexOf(':')
    trimmedPath = @getFilterQuery().trim()

    trimmedPath is '' and colon isnt -1

  getFilterQuery: ->
    query = super
    colon = query.indexOf(':')
    query = query[0...colon] if colon isnt -1
    # Normalize to backslashes on Windows
    query = query.replace(/\//g, '\\') if process.platform is 'win32'
    query

  getLineNumber: ->
    query = @filterEditorView.getText()
    colon = query.indexOf(':')
    if colon is -1
      -1
    else
      parseInt(query[colon+1..]) - 1

  setItems: (filePaths) ->
    super(@projectRelativePathsForFilePaths(filePaths))

  projectRelativePathsForFilePaths: (filePaths) ->
    # Don't regenerate project relative paths unless the file paths have changed
    if filePaths isnt @filePaths
      projectHasMultipleDirectories = atom.project.getDirectories().length > 1
      projectOptions = {}

      @filePaths = filePaths
      @projectRelativePaths = @filePaths.map (filePath) ->
        [rootPath, projectRelativePath] = atom.project.relativizePath(filePath)
        filteredProjectRelativePath = projectRelativePath
        if rootPath and projectHasMultipleDirectories
          projectRelativePath = path.join(path.basename(rootPath), projectRelativePath)
        regexSet = []
        if projectOptions[path.basename(rootPath)]
          regexSet = projectOptions[path.basename(rootPath)]
        else
          filterPath = path.join(rootPath, '.fuzzfilter')
          try
            filterContent = fs.readFileSync(filterPath, 'utf8')
            regexSet = filterContent.split("\n").filter (line) -> line.length
                                                .map (line) -> new RegExp(line)
          catch error
            if error.code isnt 'ENOENT'
              throw error
          projectOptions[path.basename(rootPath)] = regexSet
        skip = regexSet.map (regex) ->
            regex.exec(projectRelativePath)
          .filter (match) ->
            match
          .map (match) ->
            { start: match.index, end: match.index + match[0].length }
          # filteredProjectRelativePath = filteredProjectRelativePath.replace(filter, '')
        {filePath, projectRelativePath, skip}

    @projectRelativePaths

  show: ->
    @storeFocusedElement()
    @panel ?= atom.workspace.addModalPanel(item: this)
    @panel.show()
    @focusFilterEditor()

  hide: ->
    @panel?.hide()

  cancelled: ->
    @hide()
