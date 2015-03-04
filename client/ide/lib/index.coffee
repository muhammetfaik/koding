ndpane = require 'ndpane'
_ = require 'underscore'
kd = require 'kd'
$ = require 'jquery'
KDBlockingModalView = kd.BlockingModalView
KDCustomHTMLView = kd.CustomHTMLView
KDModalView = kd.ModalView
KDNotificationView = kd.NotificationView
KDSplitView = kd.SplitView
KDSplitViewPanel = kd.SplitViewPanel
remote = require('app/remote').getInstance()
globals = require 'globals'
nick = require 'app/util/nick'
showError = require 'app/util/showError'
whoami = require 'app/util/whoami'
Machine = require 'app/providers/machine'
KodingKontrol = require 'app/kite/kodingkontrol'
FSHelper = require 'app/util/fs/fshelper'
AppController = require 'app/appcontroller'
CollaborationController = require './collaborationcontroller'
IDEContentSearch = require './views/contentsearch/idecontentsearch'
IDEEditorPane = require './workspace/panes/ideeditorpane'
IDEFileFinder = require './views/filefinder/idefilefinder'
IDEFilesTabView = require './views/tabview/idefilestabview'
IDEShortcutsView = require './views/shortcutsview/ideshortcutsview'
IDEStatusBar = require './views/statusbar/idestatusbar'
IDEStatusBarMenu = require './views/statusbar/idestatusbarmenu'
IDETerminalPane = require './workspace/panes/ideterminalpane'
IDEView = require './views/tabview/ideview'
IDEWorkspace = require './workspace/ideworkspace'
splashMarkups = require './util/splash-markups'
IDEApplicationTabView = require './views/tabview/ideapplicationtabview'
AceFindAndReplaceView = require 'ace/acefindandreplaceview'
EnvironmentsMachineStateModal = require 'app/providers/environmentsmachinestatemodal'
environmentDataProvider = require 'app/userenvironmentdataprovider'

require('./routes')()


module.exports = class IDEAppController extends AppController

  _.extend @prototype, CollaborationController

  {
    Stopped, Running, NotInitialized, Terminated, Unknown, Pending,
    Starting, Building, Stopping, Rebooting, Terminating, Updating
  } = Machine.State

  {noop, warn} = kd

  @options = require './ideappcontrolleroptions'

  constructor: (options = {}, data) ->
    options.appInfo =
      type          : 'application'
      name          : 'IDE'

    super options, data

    layoutOptions     =
      splitOptions    :
        direction     : 'vertical'
        name          : 'BaseSplit'
        sizes         : [ 250, null ]
        maximums      : [ 400, null ]
        views         : [
          {
            type      : 'custom'
            name      : 'filesPane'
            paneClass : IDEFilesTabView
          },
          {
            type      : 'custom'
            name      : 'editorPane'
            paneClass : IDEView
          }
        ]

    $('body').addClass 'dark' # for theming

    appView   = @getView()
    workspace = @workspace = new IDEWorkspace { layoutOptions }
    @ideViews = []

    # todo:
    # - following two should be abstracted out into a separate api
    @layout = ndpane(16)
    @layoutMap = new Array(16*16)

    {windowController} = kd.singletons
    windowController.addFocusListener @bound 'setActivePaneFocus'

    workspace.once 'ready', =>
      panel = workspace.getView()
      appView.addSubView panel

      panel.once 'viewAppended', =>
        ideView = panel.getPaneByName 'editorPane'
        @setActiveTabView ideView.tabView
        @registerIDEView  ideView

        splitViewPanel = ideView.parent.parent
        @createStatusBar splitViewPanel
        @createFindAndReplaceView splitViewPanel

        appView.emit 'KeyViewIsSet'

        @createInitialView()
        @bindCollapseEvents()

        {@finderPane, @settingsPane} = @workspace.panel.getPaneByName 'filesPane'

        @bindRouteHandler()
        @initiateAutoSave()
        @emit 'ready'

    kd.singletons.appManager.on 'AppIsBeingShown', (app) =>

      return  unless app instanceof IDEAppController

      @setActivePaneFocus on

      # Temporary fix for IDE is not shown after
      # opening pages which uses old SplitView.
      # TODO: This needs to be fixed. ~Umut
      kd.singletons.windowController.notifyWindowResizeListeners()

      @resizeActiveTerminalPane()

    @localStorageController = kd.getSingleton('localStorageController').storage 'IDE'


  bindRouteHandler: ->

    {router, mainView} = kd.singletons

    router.on 'RouteInfoHandled', (routeInfo) =>
      if routeInfo.path.indexOf('/IDE') is -1
        if mainView.isSidebarCollapsed
          mainView.toggleSidebar()


  bindCollapseEvents: ->

    { panel } = @workspace

    filesPane = @workspace.panel.getPaneByName 'filesPane'

    # We want double click to work
    # if only the sidebar is collapsed. ~Umut
    expand = (event) =>
      kd.utils.stopDOMEvent event  if event?
      @toggleSidebar()  if @isSidebarCollapsed

    filesPane.on 'TabHandleMousedown', expand

    baseSplit = panel.layout.getSplitViewByName 'BaseSplit'
    baseSplit.resizer.on 'dblclick', @bound 'toggleSidebar'


  setActiveTabView: (tabView) ->

    return  if tabView is @activeTabView
    @setActivePaneFocus off
    @activeTabView = tabView
    @setActivePaneFocus on


  setActivePaneFocus: (state) ->

    return  unless pane = @getActivePaneView()
    return  if pane is @activePaneView

    @activePaneView = pane

    kd.utils.defer -> pane.setFocus? state


  splitTabView: (type = 'vertical', ideViewOptions) ->

    ideView        = @activeTabView.parent
    ideParent      = ideView.parent
    newIDEView     = new IDEView ideViewOptions

    splitViewPanel = @activeTabView.parent.parent
    if splitViewPanel instanceof KDSplitViewPanel
    then layout = splitViewPanel._layout
    else layout = @layout

    @activeTabView = null

    ideView.detach()

    splitView   = new KDSplitView
      type      : type
      views     : [ null, newIDEView ]

    layout.split(type is 'vertical')
    splitView._layout = layout

    @registerIDEView newIDEView

    splitView.once 'viewAppended', =>
      splitView.panels.first.attach ideView
      splitView.panels[0] = ideView.parent
      splitView.options.views[0] = ideView
      splitView.panels.forEach (panel, i) =>
        leaf = layout.leafs[i]
        panel._layout = leaf
        @layoutMap[leaf.data.offset] = panel

    ideParent.addSubView splitView
    @setActiveTabView newIDEView.tabView

    splitView.on 'ResizeDidStop', kd.utils.throttle 500, @bound 'doResize'


  mergeSplitView: ->

    panel     = @activeTabView.parent.parent
    splitView = panel.parent
    {parent}  = splitView

    return  unless panel instanceof KDSplitViewPanel

    if parent instanceof KDSplitViewPanel
      parentSplitView    = parent.parent
      panelIndexInParent = parentSplitView.panels.indexOf parent

    splitView.once 'SplitIsBeingMerged', (views) =>
      for view in views
        index = @ideViews.indexOf view
        @ideViews.splice index, 1

      @layoutMap[splitView._layout.data.offset] = parent

      @handleSplitMerge views, parent, parentSplitView, panelIndexInParent
      @doResize()

    splitView._layout.leafs.forEach (leaf) =>
      @layoutMap[leaf.data.offset] = null
    splitView._layout.merge()

    splitView.merge()


  handleSplitMerge: (views, container, parentSplitView, panelIndexInParent) ->

    ideView = new IDEView createNewEditor: no
    panes   = []

    for view in views
      {tabView} = view

      for p in tabView.panes by -1
        {pane} = tabView.removePane p, yes, (yes if tabView instanceof IDEApplicationTabView)
        panes.push pane

      view.destroy()

    container.addSubView ideView

    for pane in panes
      ideView.tabView.addPane pane

    @setActiveTabView ideView.tabView
    @registerIDEView ideView

    if parentSplitView and panelIndexInParent
      parentSplitView.options.views[panelIndexInParent] = ideView
      parentSplitView.panels[panelIndexInParent]        = ideView.parent


  openFile: (file, contents, callback = noop, emitChange) ->

    @activeTabView.emit 'FileNeedsToBeOpened', file, contents, callback, emitChange


  openMachineTerminal: (machineData) ->

    @activeTabView.emit 'MachineTerminalRequested', machineData


  openMachineWebPage: (machineData) ->

    @activeTabView.emit 'MachineWebPageRequested', machineData


  mountMachine: (machineData) ->

    # interrupt if workspace was changed
    return if machineData.uid isnt @workspaceData.machineUId

    panel        = @workspace.getView()
    filesPane    = panel.getPaneByName 'filesPane'

    path = @workspaceData?.rootPath

    path ?= if owner = machineData.getOwner()
    then "/home/#{owner}"
    else '/'

    filesPane.emit 'MachineMountRequested', machineData, path


  unmountMachine: (machineData) ->

    panel     = @workspace.getView()
    filesPane = panel.getPaneByName 'filesPane'

    filesPane.emit 'MachineUnmountRequested', machineData


  isMachineRunning: ->

    return @mountedMachine.status.state is Running


  createInitialView: ->

    kd.utils.defer =>
      @splitTabView 'horizontal', createNewEditor: no
      @getMountedMachine (err, machine) =>

        machine = new Machine { machine }  unless machine instanceof Machine

        return unless machine

        for ideView in @ideViews
          ideView.mountedMachine = @mountedMachine

        unless @isMachineRunning()
          nickname     = nick()
          machineLabel = machine.slug or machine.label
          splashs      = splashMarkups

          @fakeEditor       = @ideViews.first.createEditor()
          @fakeTabView      = @activeTabView
          @fakeTerminalView = new KDCustomHTMLView partial: splashs.getTerminal nickname
          @fakeTerminalPane = @fakeTabView.parent.createPane_ @fakeTerminalView, { name: 'Terminal' }

          @fakeFinderView   = new KDCustomHTMLView partial: splashs.getFileTree nickname, machineLabel
          @finderPane.addSubView @fakeFinderView, '.nfinder .jtreeview-wrapper'

          @fakeEditor.once 'EditorIsReady', => kd.utils.defer => @fakeEditor.setFocus no

        else
          snapshot = @localStorageController.getValue @getWorkspaceSnapshotName()

          if snapshot then @resurrectLocalSnapshot snapshot
          else
            @ideViews.first.createEditor()
            @ideViews.last.createTerminal { machine }
            @setActiveTabView @ideViews.first.tabView
            @forEachSubViewInIDEViews_ (pane) ->
              pane.isInitial = yes


  getMountedMachine: (callback = noop) ->

    kd.utils.defer =>
      environmentDataProvider.fetchMachineByUId @mountedMachineUId, (machine, ws) =>
        machine = new Machine { machine }  unless machine instanceof Machine
        @mountedMachine = machine

        callback null, @mountedMachine


  mountMachineByMachineUId: (machineUId) ->

    computeController = kd.getSingleton 'computeController'
    container         = @getView()

    environmentDataProvider.fetchMachineByUId machineUId, (machineItem) =>
      return showError 'Something went wrong. Try again.'  unless machineItem

      unless machineItem instanceof Machine
        machineItem = new Machine machine: machineItem

      @mountedMachine = machineItem

      callback = =>

        if machineItem
          {state}         = machineItem.status
          machineId       = machineItem._id
          baseMachineKite = machineItem.getBaseKite()
          isKiteConnected = baseMachineKite._state is 1


          if state is Running and isKiteConnected
            @mountMachine machineItem
            baseMachineKite.fetchTerminalSessions()

          else
            unless @machineStateModal

              @createMachineStateModal {
                state, container, machineItem, initial: yes
              }

              if state is NotInitialized
                @machineStateModal.once 'MachineTurnOnStarted', =>
                  kd.getSingleton('mainView').activitySidebar.initiateFakeCounter()

          @prepareCollaboration()

          actionRequiredStates = [Pending, Stopping, Stopped, Terminating, Terminated]
          computeController.on "public-#{machineId}", (event) =>

            if event.status in actionRequiredStates

              KodingKontrol.dcNotification?.destroy()
              KodingKontrol.dcNotification = null

              machineItem.getBaseKite( no ).disconnect()

              unless @machineStateModal
                @createMachineStateModal { state, container, machineItem }

              else
                if event.status in actionRequiredStates
                  @machineStateModal.updateStatus event

        else
          @createMachineStateModal { state: 'NotFound', container }


      @appStorage = kd.getSingleton('appStorageController').storage 'IDE', '1.0.0'
      @appStorage.fetchStorage =>

        isOnboardingModalShown = @appStorage.getValue 'isOnboardingModalShown'

        callback()


  createMachineStateModal: (options = {}) ->

    { mainView } = kd.singletons
    mainView.toggleSidebar()  if mainView.isSidebarCollapsed

    { state, container, machineItem, initial } = options
    modalOptions = { state, container, initial }
    @machineStateModal = new EnvironmentsMachineStateModal modalOptions, machineItem

    @machineStateModal.once 'KDObjectWillBeDestroyed', => @machineStateModal = null
    @machineStateModal.once 'IDEBecameReady',          => @handleIDEBecameReady machineItem


  collapseSidebar: ->

    panel        = @workspace.getView()
    splitView    = panel.layout.getSplitViewByName 'BaseSplit'
    floatedPanel = splitView.panels.first
    filesPane    = panel.getPaneByName 'filesPane'
    {tabView}    = filesPane
    desiredSize  = 250

    splitView.resizePanel 39, 0
    @getView().setClass 'sidebar-collapsed'
    floatedPanel.setClass 'floating'
    @activeFilesPaneName = tabView.activePane.name
    tabView.showPaneByName 'Dummy'

    @isSidebarCollapsed = yes

    tabView.on 'PaneDidShow', (pane) ->
      return if pane.options.name is 'Dummy'
      @expandSidebar()  if @isSidebarCollapsed


  expandSidebar: ->

    panel        = @workspace.getView()
    splitView    = panel.layout.getSplitViewByName 'BaseSplit'
    floatedPanel = splitView.panels.first
    filesPane    = panel.getPaneByName 'filesPane'

    splitView.resizePanel 250, 0
    @getView().unsetClass 'sidebar-collapsed'
    floatedPanel.unsetClass 'floating'
    @isSidebarCollapsed = no
    filesPane.tabView.showPaneByName @activeFilesPaneName


  toggleSidebar: ->

    if @isSidebarCollapsed then @expandSidebar() else @collapseSidebar()


  splitVertically: ->

    @splitTabView 'vertical'


  splitHorizontally: ->

    @splitTabView 'horizontal'

  createNewFile: do ->
    newFileSeed = 1

    return ->
      path     = "localfile:/Untitled-#{newFileSeed++}.txt@#{Date.now()}"
      file     = FSHelper.createFileInstance { path }
      contents = ''

      @openFile file, contents


  createNewTerminal: (options) ->

    { machine, path, resurrectSessions } = options

    unless machine instanceof Machine
      machine = @mountedMachine

    if @workspaceData

      {rootPath, isDefault} = @workspaceData

      if rootPath and not isDefault
        path = rootPath

    # options can be an Event instance if the initiator is
    # a shortcut, and that can have a `path` property
    # which is an Array. This check is to make sure that the
    # `path` is always the one we send explicitly here - SY
    path = null  unless typeof path is 'string'

    @activeTabView.emit 'TerminalPaneRequested', options


  #absolete: 'ctrl - alt - b' shortcut was removed (bug #82710798)
  createNewBrowser: (url) ->

    url = ''  unless typeof url is 'string'

    @activeTabView.emit 'PreviewPaneRequested', url


  createNewDrawing: (paneHash) ->

    paneHash = null unless typeof paneHash is 'string'

    @activeTabView.emit 'DrawingPaneRequested', paneHash


  moveTab: (direction) ->

    tabView = @activeTabView
    return unless tabView.parent?

    panel = tabView.parent.parent
    return  unless panel instanceof KDSplitViewPanel

    targetOffset = @layout[direction](panel._layout.data.offset)
    return  unless targetOffset?

    targetPanel = @layoutMap[targetOffset]

    {pane} = tabView.removePane tabView.getActivePane(), yes, yes

    targetPanel.subViews.first.tabView.addPane pane
    @setActiveTabView targetPanel.subViews.first.tabView
    @doResize()


  moveTabUp: -> @moveTab 'north'

  moveTabDown: -> @moveTab 'south'

  moveTabLeft: -> @moveTab 'west'

  moveTabRight: -> @moveTab 'east'


  goToLeftTab: ->

    index = @activeTabView.getActivePaneIndex()
    return if index is 0

    @activeTabView.showPaneByIndex index - 1


  goToRightTab: ->

    index = @activeTabView.getActivePaneIndex()
    return if index is @activeTabView.length - 1

    @activeTabView.showPaneByIndex index + 1


  goToTabNumber: (keyEvent) ->

    keyEvent.preventDefault()
    keyEvent.stopPropagation()

    keyCodeMap    = [ 49..57 ]
    requiredIndex = keyCodeMap.indexOf keyEvent.keyCode

    @activeTabView.showPaneByIndex requiredIndex


  goToLine: ->

    @activeTabView.emit 'GoToLineRequested'


  closeTab: ->

    @activeTabView.removePane @activeTabView.getActivePane()


  registerIDEView: (ideView) ->

    @ideViews.push ideView
    ideView.mountedMachine = @mountedMachine

    ideView.on 'PaneRemoved', (pane) =>
      ideViewLength  = 0
      ideViewLength += ideView.tabView.panes.length  for ideView in @ideViews
      delete @generatedPanes[pane.view.hash]

      if session = pane.view.remote?.session
        @mountedMachine.getBaseKite().removeFromActiveSessions session

      @statusBar.showInformation()  if ideViewLength is 0
      @writeSnapshot()

    ideView.tabView.on 'PaneAdded', (pane) =>
      @registerPane pane
      @writeSnapshot()

    ideView.on 'ChangeHappened', (change) =>
      @syncChange change  if @rtm

    ideView.on 'UpdateWorkspaceSnapshot', =>
      @writeSnapshot()


  writeSnapshot: ->

    return  unless @isMachineRunning()

    name  = @getWorkspaceSnapshotName()
    value = @getWorkspaceSnapshot()

    @localStorageController.setValue name, value


  getWorkspaceSnapshotName: ->

    return "wss.#{@mountedMachine.uid}.#{@workspaceData.slug}"


  registerPane: (pane) ->

    {view} = pane
    unless view?.hash?
      return warn 'view.hash not found, returning'

    @generatedPanes or= {}
    @generatedPanes[view.hash] = yes

    view.on 'ChangeHappened', (change) =>
      @syncChange change  if @rtm


  forEachSubViewInIDEViews_: (callback = noop, paneType) ->

    if typeof callback is 'string'
      [paneType, callback] = [callback, paneType]

    for ideView in @ideViews
      for pane in ideView.tabView.panes when pane
        return  unless view = pane.getSubViews().first
        if paneType
        then callback view  if view.getOptions().paneType is paneType
        else callback view


  updateSettings: (component, key, value) ->

    # TODO: Refactor this method by passing component type to helper method.
    Class  = if component is 'editor' then IDEEditorPane else IDETerminalPane
    method = "set#{key.capitalize()}"

    if key is 'useAutosave' # autosave is special case, handled by app manager.
      return if value then @enableAutoSave() else @disableAutoSave()

    @forEachSubViewInIDEViews_ (view) ->
      if view instanceof Class
        if component is 'editor'
          view.aceView.ace[method]? value
        else
          view.webtermView.updateSettings()


  initiateAutoSave: ->

    {editorSettingsView} = @settingsPane

    editorSettingsView.on 'SettingsFetched', =>
      @enableAutoSave()  if editorSettingsView.settings.useAutosave


  enableAutoSave: ->

    @autoSaveInterval = kd.utils.repeat 1000, =>
      @forEachSubViewInIDEViews_ 'editor', (ep) => ep.handleAutoSave()


  disableAutoSave: -> kd.utils.killRepeat @autoSaveInterval


  showShortcutsView: ->

    paneView = null

    @forEachSubViewInIDEViews_ (view) ->
      paneView = view.parent  if view instanceof IDEShortcutsView

    return paneView.parent.showPane paneView if paneView


    @activeTabView.emit 'ShortcutsViewRequested'


  getActivePaneView: ->

    return @activeTabView?.getActivePane()?.getSubViews().first


  saveFile: ->

    @getActivePaneView().emit 'SaveRequested'


  saveAs: ->

    @getActivePaneView().aceView.ace.requestSaveAs()


  saveAllFiles: ->

    @forEachSubViewInIDEViews_ 'editor', (editorPane) ->
      {ace} = editorPane.aceView
      ace.once 'FileContentRestored', -> ace.removeModifiedFromTab()
      editorPane.emit 'SaveRequested'


  previewFile: ->

    view   = @getActivePaneView()
    {file} = view.getOptions()
    return unless file

    if FSHelper.isPublicPath file.path
      # FIXME: Take care of https.
      prefix      = "[#{@mountedMachineUId}]/home/#{nick()}/Web/"
      [temp, src] = file.path.split prefix
      @createNewBrowser "#{@mountedMachine.domain}/#{src}"
    else
      @notify 'File needs to be under ~/Web folder to preview.', 'error'


  updateStatusBar: (component, data) ->

    {status} = @statusBar

    text = if component is 'editor'
      {cursor, file} = data
      """
        <p class="line">#{++cursor.row}:#{++cursor.column}</p>
        <p>#{file.name}</p>
      """

    else if component is 'terminal' then "Terminal on #{data.machineName}"

    else if component is 'searchResult'
    then """Search results for #{data.searchText}"""

    else if typeof data is 'string' then data

    else ''

    status.updatePartial text


  showStatusBarMenu: (ideView, button) ->

    paneView = @getActivePaneView()
    paneType = paneView?.getOptions().paneType or null
    delegate = button
    menu     = new IDEStatusBarMenu { paneType, paneView, delegate }

    ideView.menu = menu

    menu.on 'viewAppended', ->
      if paneType is 'editor' and paneView
        {syntaxSelector} = menu
        {ace}            = paneView.aceView

        syntaxSelector.select.setValue ace.getSyntax() or 'text'
        syntaxSelector.on 'SelectionMade', (value) =>
          ace.setSyntax value


  showFileFinder: ->

    return @fileFinder.input.setFocus()  if @fileFinder

    @fileFinder = new IDEFileFinder
    @fileFinder.once 'KDObjectWillBeDestroyed', => @fileFinder = null


  showContentSearch: ->

    return @contentSearch.findInput.setFocus()  if @contentSearch

    @contentSearch = new IDEContentSearch
    @contentSearch.once 'KDObjectWillBeDestroyed', => @contentSearch = null
    @contentSearch.once 'ViewNeedsToBeShown', (view) =>
      @activeTabView.emit 'ViewNeedsToBeShown', view


  createStatusBar: (splitViewPanel) ->

    splitViewPanel.addSubView @statusBar = new IDEStatusBar


  createFindAndReplaceView: (splitViewPanel) ->

    splitViewPanel.addSubView @findAndReplaceView = new AceFindAndReplaceView
    @findAndReplaceView.hide()
    @findAndReplaceView.on 'FindAndReplaceViewClosed', =>
      @getActivePaneView().aceView?.ace.focus()
      @isFindAndReplaceViewVisible = no


  showFindReplaceView: (withReplaceMode) ->

    view = @findAndReplaceView
    @setFindAndReplaceViewDelegate()
    @isFindAndReplaceViewVisible = yes
    view.setViewHeight withReplaceMode
    view.setTextIntoFindInput '' # FIXME: Set selected text if exists

  showFindReplaceViewWithReplaceMode: -> @showFindReplaceView yes

  hideFindAndReplaceView: ->

    @findAndReplaceView.close no


  setFindAndReplaceViewDelegate: ->

    @findAndReplaceView.setDelegate @getActivePaneView()?.aceView or null


  showFindAndReplaceViewIfNecessary: ->

    if @isFindAndReplaceViewVisible
      @showFindReplaceView @findAndReplaceView.mode is 'replace'


  handleFileDeleted: (file) ->

    for ideView in @ideViews
      ideView.tabView.emit 'TabNeedsToBeClosed', file


  handleIDEBecameReady: (machine) ->

    {finderController} = @finderPane
    if @workspaceData
      finderController.updateMachineRoot @mountedMachine.uid, @workspaceData.rootPath
    else
      finderController.reset()

    snapshot = @localStorageController.getValue @getWorkspaceSnapshotName()

    machine.getBaseKite().fetchTerminalSessions()

    unless @fakeViewsDestroyed
      for ideView in @ideViews
        {tabView}  = ideView
        activePane = tabView.getActivePane()

        tabView.removePane activePane  if activePane

      @fakeFinderView?.destroy()
      @fakeViewsDestroyed = yes

    if snapshot then @resurrectLocalSnapshot snapshot
    else
      @ideViews.first.createEditor()
      @ideViews.last.createTerminal { machine }
      @setActiveTabView @ideViews.first.tabView


  resurrectLocalSnapshot: (snapshot) ->

    for key, value of snapshot when value
      @createPaneFromChange value, yes


  toggleFullscreenIDEView: ->

    @activeTabView.parent.toggleFullscreen()


  doResize: ->

    @forEachSubViewInIDEViews_ (pane) =>
      {paneType} = pane.options
      switch paneType
        when 'terminal'
          { webtermView } = pane
          { terminal }    = webtermView

          terminal.windowDidResize()  if terminal?

          {isActive} = @getActiveInstance()

          if not @isInSession and isActive
            kd.utils.wait 400, -> # defer was not enough.
              webtermView.triggerFitToWindow()

        when 'editor'
          height = pane.getHeight()
          {ace}  = pane.aceView

          if ace?.editor?
            ace.setHeight height
            ace.editor.resize()


  notify: (title, cssClass = 'success', type = 'mini', duration = 4000) ->

    return unless title
    new KDNotificationView { title, cssClass, type, duration }


  resizeActiveTerminalPane: ->

    for ideView in @ideViews
      pane = ideView.tabView.getActivePane()
      if pane and pane.view instanceof IDETerminalPane
        pane.view.webtermView.terminal?.updateSize()


  removePaneFromTabView: (pane, shouldDetach = no) ->

    paneView = pane.parent
    tabView  = paneView.parent
    tabView.removePane paneView


  getWorkspaceSnapshot: ->

    panes = {}

    @forEachSubViewInIDEViews_ (pane) ->
      return  unless pane
      return  if not pane.serialize or (@isInSession and pane.isInitial)

      data = pane.serialize()
      panes[data.hash] =
        type    : 'NewPaneCreated'
        context : data

    return panes


  changeActiveTabView: (paneType) ->

    if paneType is 'terminal'
      @setActiveTabView @ideViews.last.tabView
    else
      @setActiveTabView @ideViews.first.tabView


  syncChange: (change) ->

    {context} = change

    return  if not @rtm or not @rtm.isReady or not context

    {paneHash} = context
    nickname   = nick()

    if change.origin is nickname

      if context.paneType is 'editor'

        if change.type is 'NewPaneCreated'

          {content, path} = context.file

          string = @rtm.getFromModel path

          unless string
            @rtm.create 'string', path, content

        else if change.type is 'ContentChange'

          {content, path} = context.file
          string = @rtm.getFromModel path
          string.setText content  if string

        if context.file?.content
          delete context.file.content

      @changes.push change

    switch change.type

      when 'NewPaneCreated'
        @mySnapshot.set paneHash, change  if paneHash

      when 'PaneRemoved'
        @mySnapshot.delete paneHash  if paneHash


  handleChange: (change) ->

    {context, origin, type} = change

    return if not context or not origin or origin is nick()

    amIWatchingChangeOwner = @myWatchMap.keys().indexOf(origin) > -1

    if amIWatchingChangeOwner or type is 'CursorActivity'
      targetPane = @getPaneByChange change

      if type is 'NewPaneCreated'
        @createPaneFromChange change

      else if type in ['TabChanged', 'PaneRemoved']
        paneView = targetPane?.parent
        tabView  = paneView?.parent
        ideView  = tabView?.parent

        return unless ideView

        ideView.suppressChangeHandlers = yes

        if type is 'TabChanged'
          tabView.showPane paneView
        else
          tabView.removePane paneView

        ideView.suppressChangeHandlers = no


      targetPane?.handleChange? change, @rtm


  getPaneByChange: (change) ->

    return unless change.context

    return @finderPane  if change.type is 'FileTreeInteraction'

    targetPane = null
    {context}  = change
    {paneType} = context

    @forEachSubViewInIDEViews_ paneType, (pane) =>

      if paneType is 'editor'
        if pane.getFile()?.path is context.file?.path
          targetPane = pane

      else
        targetPane = pane  if pane.hash is context.paneHash

    return targetPane


  createPaneFromChange: (change = {}, isFromLocalStorage) ->

    return  if not @rtm and not isFromLocalStorage

    { context } = change
    return  unless context

    paneHash = context.paneHash or context.hash
    currentSnapshot = @getWorkspaceSnapshot()

    return  if currentSnapshot[paneHash]

    { paneType } = context

    return  if not paneType or not paneHash

    @changeActiveTabView paneType

    switch paneType
      when 'terminal'
        terminalOptions =
          machine       : @mountedMachine
          session       : context.session
          hash          : paneHash
          joinUser      : @collaborationHost or nick()
          fitToWindow   : not @isInSession

        @createNewTerminal terminalOptions

      when 'editor'
        { file }      = context
        { path }      = file
        options       = { path, machine : @mountedMachine }
        file          = FSHelper.createFileInstance options
        file.paneHash = paneHash

        if @rtm?.realtimeDoc
          content = @rtm.getFromModel(path)?.getText() or ''
          @openFile file, content, noop, no
        else if file.isDummyFile()
          @openFile file, context.file.content, noop, no
        else
          file.fetchContents (err, contents = '') =>
            return showError err  if err
            @changeActiveTabView paneType
            @openFile file, contents, noop, no

      when 'drawing'
        @createNewDrawing paneHash

    if @mySnapshot
      unless @mySnapshot.get paneHash
        @mySnapshot.set paneHash, change


  showModal: (modalOptions = {}, callback = noop) ->
    return  if @modal

    modalOptions.overlay  ?= yes
    modalOptions.blocking ?= no
    modalOptions.buttons or=
      Yes        :
        cssClass : 'solid green medium'
        callback : callback
      No         :
        cssClass : 'solid light-gray medium'
        callback : => @modal.destroy()

    ModalClass = if modalOptions.blocking then KDBlockingModalView else KDModalView

    @modal = new ModalClass modalOptions
    @modal.once 'KDObjectWillBeDestroyed', =>
      delete @modal


  quit: ->

    @cleanupCollaboration()

    kd.singletons.router.handleRoute '/IDE'
    kd.singletons.appManager.quit this


  removeParticipantCursorWidget: (targetUser) ->

    @forEachSubViewInIDEViews_ 'editor', (editorPane) =>
      editorPane.removeParticipantCursorWidget targetUser


  makeReadOnly: ->

    return  if @isReadOnly

    @isReadOnly = yes
    ideView.isReadOnly = yes  for ideView in @ideViews
    @forEachSubViewInIDEViews_ (pane) -> pane.makeReadOnly()
    @finderPane.makeReadOnly()
    @getView().setClass 'read-only'


  makeEditable: ->

    return  unless @isReadOnly

    @isReadOnly = no
    ideView.isReadOnly = no  for ideView in @ideViews
    @forEachSubViewInIDEViews_ (pane) -> pane.makeEditable()
    @finderPane.makeEditable()
    @getView().unsetClass 'read-only'

  deleteWorkspaceRootFolder: (machineUId, rootPath) ->

    @finderPane.emit 'DeleteWorkspaceFiles', machineUId, rootPath


  getActiveInstance: ->

    {appControllers} = kd.singletons.appManager
    instance = appControllers.IDE.instances[appControllers.IDE.lastActiveIndex]

    return {instance, isActive: instance is this}
