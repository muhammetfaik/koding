immutable = require 'immutable'
toImmutable = require 'app/util/toImmutable'
KodingFluxStore = require 'app/flux/base/store'
actionTypes = require '../actiontypes'

module.exports = class HomeTeamBillingFormValuesStore extends KodingFluxStore

  @getterPath = 'HomeTeamBillingFormValuesStore'

  getInitialState: -> defaultValues()


  initialize: ->

    @on actionTypes.SET_TEAM_BILLING_INPUT_VALUE, handleSetValue
    @on actionTypes.RESET_TEAM_BILLING_INPUT_VALUES, defaultValues


handleSetValue = (values, { type, value }) ->
  values.withMutations (values) ->
    values
      .set 'isEdited', yes
      .set type, value


defaultValues = ->
  return toImmutable
    number: ''
    expirationMonth: ''
    expirationYear: ''
    cvc: ''
    fullName: ''
    email: ''
    isEdited: no

