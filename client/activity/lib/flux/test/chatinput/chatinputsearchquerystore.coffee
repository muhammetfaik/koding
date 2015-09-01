{ expect } = require 'chai'

Reactor = require 'app/flux/reactor'

ChatInputSearchQueryStore = require 'activity/flux/stores/chatinput/chatinputsearchquerystore'
actions = require 'activity/flux/actions/actiontypes'

describe 'ChatInputSearchQueryStore', ->

  beforeEach ->

    @reactor = new Reactor
    @reactor.registerStores chatInputSearchQuery : ChatInputSearchQueryStore


  describe '#setQuery', ->

    it 'sets current query to a given value', ->

      query1 = 'qwerty'
      query2 = '123456'
      initiatorId = 'test'

      @reactor.dispatch actions.SET_CHAT_INPUT_SEARCH_QUERY, { initiatorId, query : query1 }
      query = @reactor.evaluate(['chatInputSearchQuery']).get initiatorId

      expect(query).to.equal query1

      @reactor.dispatch actions.SET_CHAT_INPUT_SEARCH_QUERY, { initiatorId, query: query2 }
      query = @reactor.evaluate(['chatInputSearchQuery']).get initiatorId

      expect(query).to.equal query2


  describe '#unsetQuery', ->

    it 'clears current query', ->

      testQuery = 'qwerty'
      initiatorId = 'test'

      @reactor.dispatch actions.SET_CHAT_INPUT_SEARCH_QUERY, { initiatorId, query : testQuery }
      query = @reactor.evaluate(['chatInputSearchQuery']).get initiatorId

      expect(query).to.equal testQuery

      @reactor.dispatch actions.UNSET_CHAT_INPUT_SEARCH_QUERY, { initiatorId }
      query = @reactor.evaluate(['chatInputSearchQuery']).get initiatorId

      expect(query).to.be.undefined

