browserid   = require 'browserid-consumer'
url         = require 'url'
querystring = require 'querystring'
_           = require 'underscore'
uuid        = require 'node-uuid'
http        = require 'http'
https       = require 'https'
async       = require 'async'


#
# Attach intertwinkles to the given Express app and RoomManager iorooms.
#
attach = (config, app, iorooms) ->
  if iorooms?
    # Build a list of everyone who is currently in the room, anonymous or no.
    build_room_users_list_for = (room, self_session, cb) ->
      iorooms.getSessionsInRoom room, (err, sessions) ->
        if err? then return cb(err)
        room_list = []
        for session in sessions
          authenticated = session.auth?.email? and session.groups?.users?
          if authenticated
            user = _.find session.groups.users, (u) -> u.email == session.auth.email
            info = { name: user.name, icon: user.icon }
          else
            info = { name: "Anonymous", icon: null }
          info.anon_id = session.anon_id
          room_list.push(info)
         cb(err, { room: room, list: room_list })

    # Log in
    iorooms.onChannel 'verify', (socket, reqdata) ->
      auth.verify reqdata.assertion, config, (err, auth, groupdata) ->
        if err?
          socket.emit("error", err)
          socket.session.auth = null
          socket.session.groups = null
          iorooms.saveSession(socket.session)
          console.log "error", err, auth, groupdata
        else
          socket.session.auth = auth
          socket.session.auth.user_id = _.find(groupdata.users, (u) -> u.email = auth.email).id
          socket.session.groups = { groups: groupdata.groups, users: groupdata.users }
          iorooms.saveSession socket.session, (err) ->
            if (err) then return socket.emit "error", {error: err}

            socket.emit reqdata.callback, {
              user_id: socket.session.auth.user_id
              email: socket.session.auth.email,
              groups: socket.session.groups,
              message: groupdata.message
            }

            #FIXME: Broadcast back to other sockets in this session that they
            #have logged in. Maybe use a dedicated listener (e.g. 'auth')
            #instead of a 'once' listener with reqdata.callback

            # Update all room's user lists to include our logged in name
            rooms = iorooms.sessionRooms[socket.session.sid] or []
            for room in rooms
              do (room) ->
                build_room_users_list_for room, socket.session, (err, users) ->
                  socket.emit "room_users", users
                  socket.broadcast.to(room).emit "room_users", users

    # Log out
    iorooms.onChannel "logout", (socket, data) ->
      # Keep the session around, so that we maintain our socket list.
      socket.session.auth = null
      socket.session.groups = null
      iorooms.saveSession socket.session, ->
        socket.emit(data.callback, {status: "success"})

      # Update the list of room users to remove our logged in name
      rooms = iorooms.sessionRooms[socket.session.sid] or []
      for room in rooms
        do (room) ->
          build_room_users_list_for room, socket.session, (err, users) ->
            socket.emit "room_users", users
            socket.broadcast.to(room).emit "room_users", users

    # Edit the more trivial profile details (email, name, color)
    iorooms.onChannel "edit_profile", (socket, data) ->
      respond = (err, res) ->
        if err?
          socket.emit data.callback or "error", {error: err}
        else if data.callback?
          socket.emit data.callback, res

      if socket.session.auth.email != data.model.email
        return respond("Not authorized")
      if not data.model.name
        return respond("Invalid name")
      if not /[0-9a-fA-F]{6}/.test(data.model.icon.color)
        return respond("Invalid color #{data.model.icon.color}")
      if isNaN(data.model.icon.id)
        return respond("Invalid icon id")

      profile_api_url = config.intertwinkles.api_url + "/api/profiles/"

      utils.post_data profile_api_url, {
        api_key: config.intertwinkles.api_key,
        user: socket.session.auth.email
        name: data.model.name
        icon_id: data.model.icon.id
        icon_color: data.model.icon.color
      }, (err, data) ->
        return respond(err) if err?
        socket.session.groups?.users[data.model.id] = data.model
        respond(null, model: data.model)

    # Get notifications
    iorooms.onChannel "get_notifications", (socket, data) ->
      return unless auth.is_authenticated(socket.session)
      utils.get_json "#{config.intertwinkles.api_url}/api/notifications/", {
        api_key: config.intertwinkles.api_key
        user: socket.session.auth.email
      }, (err, data) ->
        return socket.emit "error", {error: err} if err?
        console.log data
        socket.emit "notifications", data

    # Get events
    iorooms.onChannel "get_events", (socket, data) ->
      unless (data.query? and data.callback? and
          auth.is_authenticated(socket.session))
        return socket.emit "error", {error: "Invalid events query"}
      events.get_events_for socket.session.auth.email, data.query, config, (err, results) ->
          socket.emit data.callback, {events: results.events}

    # Join room
    iorooms.on "join", (data) ->
      join = (err) ->
        if err? then return data.socket.emit "error", {error: err}
        build_room_users_list_for data.room, data.socket.session, (err, users) ->
          if err? then return data.socket.emit "error", {error: err}
          # inform the client of its anon_id on first join.
          data.socket.emit "room_users", _.extend {
              anon_id: data.socket.session.anon_id
            }, users
          if data.first
            # Tell everyone else in the room.
            data.socket.broadcast.to(data.room).emit "room_users", users
      if not data.socket.session.anon_id?
        data.socket.session.anon_id = uuid.v4()
        iorooms.saveSession(data.socket.session, join)
      else
        join()

    # Leave room
    iorooms.on "leave", (data) ->
      return unless data.last
      build_room_users_list_for data.room, data.socket.session, (err, users) ->
        if err? then return data.socket.emit "error", {error: err}
        data.socket.broadcast.to(data.room).emit "room_users", users

  if app?
    null
    # TODO: Add routes to "/verify", "/logout", "/edit_profile" etc for AJAX

#
# Authorize a request originating from the browser with Mozilla persona and the
# InterTwinkles api server.
#
auth = {}
auth.verify = (assertion, config, callback) ->
  unless config.intertwinkles?.api_url?
    throw "Missing required config parameter: intertwinkles_api_url"
  unless config.intertwinkles?.api_key?
    throw "Missing required config parameter: intertwinkles_api_key"

  # Two-step operation: first, verify the assertion with Mozilla Persona.
  # Second, authorize the user with the InterTwinkles api server.
  #audience = "#{config.host}:#{config.port}"
  audience = config.intertwinkles.api_url.split("://")[1]
  browserid.verify assertion, audience, (err, auth) ->
    if (err)
      callback({'error': err})
    else
      query = {
        api_key: config.intertwinkles.api_key
        user: auth.email
      }
      # BrowserID success; now authorize with InterTwinkles.
      utils.get_json config.intertwinkles.api_url + "/api/groups/", query, (err, groups) ->
        callback(err, auth, groups)

# Clear all session properties that intertwinkles adds when we log in.
auth.clear_auth_session = (session) ->
  delete session.auth
  delete session.groups

auth.is_authenticated = (session) -> return session.auth?.email?

#
# Permissions. Expects 'session' to have auth and groups params as populated by
# 'verify' above, and model to have the following schema:
#   sharing: {
#     group_id: String          -- a group ID from InterTwinkles
#     public_view_until: Date   -- Date until expiry of public viewing. Set to 
#                                  far future for perpetual public viewing.
#     public_edit_until: Date   -- Date until expiry of public editing. Set to 
#                                  far future for perpetual public viewing.
#     extra_viewers: [String]   -- A list of email addresses of people who are
#                                  also allowed to view.
#     extra_editors: [String]   -- A list of email addresses of people who are
#                                  also allowed to edit.
#     advertise: Boolean        -- List/index this document publicly?
#   }
#
#  Assumptions: Edit permissions imply view permissions.  Group association
#  implies all permissions granted to members of that group. Absence of group
#  association implies the public can view and edit (e.g. etherpad style;
#  relies on secret URL for security).
#
#  If a document is owned (e.g. has a group, or explicit extra_editors), only
#  owners (group members or explicit editors) can change sharing options.
#
sharing = {}
sharing.can_view = (session, model) ->
  # Editing implies viewing.
  return true if sharing.can_edit(session, model)
  # Is this public for viewing but not editing?
  return true if model.sharing?.public_view_until > new Date()
  # Are we specifically listed as an extra viewer?
  return true if (
    model.sharing?.extra_viewers? and
    session.auth?.email? and
    model.sharing.extra_viewers.indexOf(session.auth.email) != -1
  )
  return false

sharing.can_edit = (session, model) ->
  # No group? Everyone can edit.
  return true if not model.sharing?.group_id?
  # If it is associated with a group, it might be marked public.
  return true if model.sharing?.public_edit_until > new Date()
  # Otherwise, we have to be signed in.
  return false if not session.auth?.email?
  # Or we could be in a group that owns this.
  return true if _.find(session.groups.groups, (g) -> "" + g.id == "" + model.sharing?.group_id)
  # Or marked as specifically allowed to edit
  return true if (
    model.sharing?.extra_editors? and
    session.auth?.email? and
    model.sharing.extra_editors.indexOf(session.auth.email) != -1
  )
  return false

sharing.can_change_sharing = (session, model) ->
  # Doesn't belong to a group, go ahead.
  return true if not model.sharing?.group_id? and (
    (model.sharing?.extra_editors or []).length == 0
  )
  # Doc belongs to a group.  Must be logged in.
  return false unless session?.auth?.email
  # All good if you belong to the group.
  return true if _.find(
    session?.groups?.groups or [],
    (g) -> "" + g.id == "" + model.sharing.group_id
  )
  # All good if you are an explicit extra editor
  return true if _.find(model.sharing?.extra_editors or [], session.auth.email)
  return false

# Return a copy of the sharing properties of this model which do not contain
# email addresses or any other details the given user session shouldn't see. 
# The main rub: sharing settings might specify a list of email addresses of
# people who can edit or view. But a doc might also be made public for a period
# of time.  If it is public, and we aren't in the group or in the list of
# approved editors/viewers, hide email addresses.
sharing.clean_sharing = (session, model) ->
  return {} if not model.sharing?
  cleaned = {
    group_id: model.sharing.group_id
    public_view_until: model.sharing.public_view_until
    public_edit_until: model.sharing.public_edit_until
    advertise: model.sharing.advertise
  }
  # If we aren't signed in (or there are no specified 'extra_viewers' or
  # 'extra_editors' to show), don't return any extra viewers or extra editors.
  return cleaned if not session?.auth?.email? or not (model.sharing.extra_viewers? or model.sharing.extra_editors?)
  # If we're in the group, or in the list of approved viewers/editors, show the
  # addresses.
  email = session.auth.email
  group = _.find(session.groups.groups, (g) -> "" + g.id == "" + model.sharing.group_id)
  if (group or
      model.sharing.extra_editors?.indexOf(email) != -1 or
      model.sharing.extra_viewers?.indexOf(email) != -1)
    cleaned.extra_editors = (e for e in model.sharing.extra_editors or [])
    cleaned.extra_viewers = (e for e in model.sharing.extra_viewers or [])
  return cleaned

#
# Mongoose helpers
#

mongo = {}

# List all the documents in `schema` (a Mongo/Mongoose collection) which are
# currently public.  Use for providing a dashboard listing of documents.
mongo.list_public_documents = (schema, session, cb, condition={}, sort="modified", skip=0, limit=20, clean=true) ->
  # Find the public documents.
  query = _.extend({
    "sharing.advertise": true
    $or: [
      { "sharing.group_id": null },
      { "sharing.public_edit_until": { $gt: new Date() }}
      { "sharing.public_view_until": { $gt: new Date() }}
    ]
  }, condition)
  schema.find(query).sort(sort).skip(skip).limit(limit).exec (err, docs) ->
    return cb(err) if err?
    if clean
      for doc in docs
        doc.sharing = sharing.clean_sharing(session, doc)
    cb(null, docs)

# List all the documents in `schema` (a Mongo/Mongoose collection) which belong
# to the given session.  Use for providing a dashboard listing of documents.
mongo.list_group_documents = (schema, session, cb, condition={}, sort="modified", skip=0, limit=20, clean=true) ->
  # Find the group documents
  if not session?.auth?.email?
    cb(null, []) # Not signed in; we have no group docs.
  else
    query = _.extend({
      $or: [
        {"sharing.group_id": { $in : (id for id,g of session.groups?.groups or []) }}
        {"sharing.extra_editors": session.auth.email}
        {"sharing.extra_viewers": session.auth.email}
      ]
    }, condition)
    schema.find(query).sort(sort).skip(skip).limit(limit).exec (err, docs) ->
      return cb(err) if err?
      if clean
        for doc in docs
          doc.sharing = sharing.clean_sharing(session, doc)
      cb(null, docs)

# List both public and group documents, in an object {public: [docs], group: [docs]}
mongo.list_accessible_documents = (schema, session, cb, condition={}, sort="modified", skip=0, limit=20, clean=true) ->
  async.series [
    (done) -> mongo.list_group_documents(schema, session, done, condition, sort, skip, limit, clean)
    (done) -> mongo.list_public_documents(schema, session, done, condition, sort, skip, limit, clean)
  ], (err, res) ->
    cb(err, { group: res[0], public: res[1] })

#
# Events
#

events = {}

events.get_events_for = (user, query, config, callback) ->
  events_api_url = config.intertwinkles.api_url + "/api/events/"
  get_data = {
    event: query,
    user: user,
    api_key: config.intertwinkles.api_key
  }
  get_data.event = JSON.stringify(get_data.event)
  utils.get_json(events_api_url, get_data, callback)

events.timeout_queue = {}
events.post_event_for = (user, query, config, callback, timeout) ->
  # If we are passed a timeout argument, store the results of the event posting
  # for the duration of that time, and return that data while it's stored.
  # The event is considered the same if it shares the same properties with the
  # exception of "data" and "date".
  key = null
  if timeout?
    key = [query.application, query.entity, query.type, query.user, query.group].join(":")
    if events.timeout_queue[key]
      return callback?(null, events.timeout_queue[key])

  # Prepare the event data.
  events_api_url = config.intertwinkles.api_url + "/api/events/"
  post = {
    event: query
    user: user
    api_key: config.intertwinkles.api_key
  }
  post.event = JSON.stringify(post.event)

  # Post the event, and respond.
  utils.post_data(events_api_url, post, (err, data) ->
    if timeout? and not err?
      events.timeout_queue[key] = data
      setTimeout (-> delete events.timeout_queue[key]), timeout
    callback?(err, data)
  )

#
# Utilities
#
utils = {}
utils.slugify = (name) -> return name.toLowerCase().replace(/[^-a-z0-9]+/g, '-')
# GET the resource residing at get_url with search query data `query`,
# interpreting the response as JSON.
utils.get_json = (get_url, query, callback) ->
  parsed_url = url.parse(get_url)
  httplib = if parsed_url.protocol == 'https:' then https else http
  opts = {
    hostname: parsed_url.hostname
    port: parseInt(parsed_url.port)
    path: "#{parsed_url.pathname}?#{querystring.stringify(query)}"
  }
  req = httplib.get(opts, (res) ->
    res.setEncoding('utf8')
    data = ''
    res.on 'data', (chunk) -> data += chunk
    res.on 'end', ->
      if res.statusCode != 200
        return callback {error: "Intertwinkles status #{res.statusCode}"}
      try
        json = JSON.parse(data)
      catch e
        return callback {error: e}
      if json.error?
        callback(json)
      else
        callback(null, json)
  ).on("error", (e) -> callback(error: e))

# Post the given data to the given URL as form encoded data; interpret the
# response as JSON.
utils.post_data = (post_url, data, callback) ->
  post_url = url.parse(post_url)
  httplib = if post_url.protocol == 'https:' then https else http
  opts = {
    hostname: post_url.hostname
    port: parseInt(post_url.port)
    path: post_url.pathname
    method: 'POST'
  }
  req = httplib.request opts, (res) ->
    res.setEncoding('utf8')
    answer = ''
    res.on 'data', (chunk) -> answer += chunk
    res.on 'end', ->
      return unless callback?
      if res.statusCode == 200
        try
          json = JSON.parse(answer)
        catch e
          return callback {error: e}
        if json.error?
          callback(json)
        callback(null, json)
      else
        callback({error: "Intertwinkles status #{res.statusCode}", message: answer})
  data = querystring.stringify(data)
  req.setHeader("Content-Type", "application/x-www-form-urlencoded")
  req.setHeader("Content-Length", data.length)
  req.write(data)
  req.end()

module.exports = _.extend {attach}, auth, sharing, mongo, events, utils
