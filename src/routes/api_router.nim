# SPDX-License-Identifier: AGPL-3.0-only
#
# Machine-readable API derived from the JSON API work in yao177/nitter-plus,
# adapted to current Nitter and extended for StarIntel collection workflows.

import asyncdispatch, json, options, sequtils, strutils, tables, times
from os import getEnv

import jester

import router_utils
import ".."/[api, formatters, query, redis_cache, types, utils]

export json

const
  jsonHeaders* = {"Content-Type": "application/json; charset=utf-8"}
  validUsernameChars = {'a'..'z', 'A'..'Z', '0'..'9', '_'}
  twitterBaseUrl = "https://x.com"
  apiVersion = "starintel-nitter/v1"

let
  apiEnabled = getEnv("NITTER_ENABLE_API", "false").toLowerAscii in
    ["1", "true", "yes", "on"]
  apiKey = getEnv("NITTER_API_KEY", "")

proc jsonError*(message: string): JsonNode =
  %*{"error": message, "apiVersion": apiVersion}

proc isValidUsername(name: string): bool =
  name.len > 0 and name.len <= 15 and name.allCharsInSet(validUsernameChars)

proc isValidTweetId*(id: string): bool =
  id.len > 0 and id.len <= 19 and id.allCharsInSet({'0'..'9'})

proc toIso(dt: DateTime): JsonNode =
  if dt.year <= 1:
    newJNull()
  else:
    %dt.utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc retrievedAt(): string =
  now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc verifiedToJson(verifiedType: VerifiedType): JsonNode =
  if verifiedType == VerifiedType.none:
    newJNull()
  else:
    %($verifiedType)

proc isAbsoluteUrl(url: string): bool =
  url.startsWith("http://") or url.startsWith("https://")

proc toTwitterMediaUrl(url: string): string =
  if url.len == 0 or url.startsWith('#') or url.isAbsoluteUrl:
    return url

  let normalized =
    if url.startsWith('/'):
      url[1 .. ^1]
    else:
      url

  let slashIdx = normalized.find('/')
  let host =
    if slashIdx >= 0: normalized[0 ..< slashIdx]
    else: normalized

  if '.' in host:
    return https & normalized

  https & twimg & normalized

proc toTwitterStatusUrl(tweet: Tweet): string =
  if tweet.isNil or tweet.id == 0:
    return ""

  let username = if tweet.user.username.len > 0: tweet.user.username else: "i"
  twitterBaseUrl & "/" & username & "/status/" & $tweet.id

proc toTwitterUserUrl(user: User): string =
  if user.username.len == 0: "" else: twitterBaseUrl & "/" & user.username

proc getVariants(video: Video; playbackType: VideoType): seq[VideoVariant] =
  video.variants.filterIt(it.contentType == playbackType and it.url.len > 0)

proc playableType(video: Video): VideoType =
  if video.getVariants(video.playbackType).len > 0:
    return video.playbackType
  if video.getVariants(m3u8).len > 0:
    return m3u8
  if video.getVariants(mp4).len > 0:
    return mp4
  if video.getVariants(vmap).len > 0:
    return vmap
  video.playbackType

proc preferredVariant(video: Video; playbackType: VideoType): Option[VideoVariant] =
  var
    best: VideoVariant
    found = false

  for variant in video.variants:
    if variant.contentType != playbackType or variant.url.len == 0:
      continue
    if not found or variant.resolution > best.resolution or
       (variant.resolution == best.resolution and variant.bitrate >= best.bitrate):
      best = variant
      found = true

  if found:
    some(best)
  else:
    none(VideoVariant)

proc preferredVideoUrl(video: Video): string =
  let variant = video.preferredVariant(video.playableType)
  if variant.isSome: variant.get.url else: video.url

proc provenanceToJson(canonicalUrl: string; resource: string): JsonNode =
  %*{
    "apiVersion": apiVersion,
    "collector": "starintel-labs/nitter",
    "upstream": "zedeus/nitter",
    "resource": resource,
    "canonicalUrl": canonicalUrl,
    "retrievedAt": retrievedAt()
  }

proc videoVariantToJson(variant: VideoVariant): JsonNode =
  %*{
    "bitrate": variant.bitrate,
    "contentType": $variant.contentType,
    "url": toTwitterMediaUrl(variant.url),
    "resolution": variant.resolution
  }

proc userToJson*(user: User): JsonNode =
  %*{
    "id": user.id,
    "username": user.username,
    "fullname": user.fullname,
    "url": toTwitterUserUrl(user),
    "bio": stripHtml(user.bio),
    "location": user.location,
    "website": user.website,
    "avatar": toTwitterMediaUrl(user.getUserPic("_400x400")),
    "banner": toTwitterMediaUrl(user.banner),
    "following": user.following,
    "followers": user.followers,
    "posts": user.tweets,
    "likes": user.likes,
    "media": user.media,
    "verifiedType": verifiedToJson(user.verifiedType),
    "protected": user.protected,
    "suspended": user.suspended,
    "joinedAt": toIso(user.joinDate)
  }

proc mediaToJson(media: Media): JsonNode =
  case media.kind
  of photoMedia:
    %*{
      "type": "photo",
      "url": toTwitterMediaUrl(media.photo.url),
      "altText": media.photo.altText
    }
  of videoMedia:
    let
      variants = media.video.variants.filterIt(it.url.len > 0)
      playbackType = media.video.playableType
    %*{
      "type": "video",
      "url": toTwitterMediaUrl(media.video.preferredVideoUrl),
      "thumbnail": toTwitterMediaUrl(media.video.thumb),
      "available": media.video.available,
      "reason": media.video.reason,
      "durationMs": media.video.durationMs,
      "playbackType": $playbackType,
      "variants": variants.mapIt(videoVariantToJson(it))
    }
  of gifMedia:
    %*{
      "type": "gif",
      "url": toTwitterMediaUrl(media.gif.url),
      "thumbnail": toTwitterMediaUrl(media.gif.thumb),
      "altText": media.gif.altText
    }

proc pollToJson(poll: Poll): JsonNode =
  var options = newJArray()
  for i, text in poll.options:
    let votes = if i < poll.values.len: poll.values[i] else: 0
    options.add %*{
      "label": text,
      "votes": votes,
      "leading": i == poll.leader
    }

  %*{
    "options": options,
    "votes": poll.votes,
    "status": poll.status
  }

proc articlePreviewToJson(article: ArticlePreview): JsonNode =
  %*{
    "title": article.title,
    "previewText": article.previewText,
    "coverImage": toTwitterMediaUrl(article.coverImage),
    "tweetId": $article.tweetId
  }

proc tweetToJson*(tweet: Tweet; includeQuote=true): JsonNode =
  if tweet.isNil:
    return newJNull()

  let canonicalUrl = toTwitterStatusUrl(tweet)
  var node = %*{
    "id": $tweet.id,
    "threadId": $tweet.threadId,
    "replyId": $tweet.replyId,
    "url": canonicalUrl,
    "user": userToJson(tweet.user),
    "text": stripHtml(tweet.text),
    "html": tweet.text,
    "createdAt": toIso(tweet.time),
    "replyingTo": tweet.reply,
    "pinned": tweet.pinned,
    "hasThread": tweet.hasThread,
    "available": tweet.available,
    "tombstone": tweet.tombstone,
    "location": tweet.location,
    "stats": %*{
      "replies": tweet.stats.replies,
      "retweets": tweet.stats.retweets,
      "likes": tweet.stats.likes,
      "views": tweet.stats.views
    },
    "media": tweet.media.mapIt(mediaToJson(it)),
    "note": tweet.note,
    "isAd": tweet.isAd,
    "isAI": tweet.isAI,
    "provenance": provenanceToJson(canonicalUrl, "post")
  }

  if tweet.poll.isSome:
    node["poll"] = pollToJson(tweet.poll.get)
  if tweet.articlePreview.isSome:
    node["articlePreview"] = articlePreviewToJson(tweet.articlePreview.get)
  if tweet.attribution.isSome:
    node["attribution"] = userToJson(tweet.attribution.get)
  if includeQuote and tweet.quote.isSome:
    node["quote"] = tweetToJson(tweet.quote.get, includeQuote=false)
  if tweet.retweet.isSome:
    node["retweet"] = tweetToJson(tweet.retweet.get, includeQuote=false)

  node

proc tweetsToJson*(tweets: Tweets): JsonNode =
  result = newJArray()
  for tweet in tweets:
    result.add tweetToJson(tweet)

proc timelineToJson*(timeline: Timeline; resource="timeline"): JsonNode =
  var items = newJArray()
  for group in timeline.content:
    for tweet in group:
      items.add tweetToJson(tweet)

  %*{
    "items": items,
    "nextCursor": timeline.bottom,
    "previousCursor": timeline.top,
    "beginning": timeline.beginning,
    "provenance": provenanceToJson("", resource)
  }

proc postSearchToJson*(query: Query; cursor: string): Future[JsonNode] {.async.} =
  let timeline = await getGraphTweetSearch(query, cursor)
  result = timelineToJson(timeline, "search")
  result["query"] = %query.text

proc authToken*(req: Request): string =
  let headers = req.getNativeReq().headers
  let bearer = headers.getOrDefault("Authorization")
  if bearer.startsWith("Bearer "):
    return bearer[7..^1]
  headers.getOrDefault("X-API-Key")

template requireApi*(request: Request) =
  if not apiEnabled:
    resp Http404, jsonHeaders, $jsonError("API is disabled")
  if apiKey.len > 0 and authToken(request) != apiKey:
    resp Http401, jsonHeaders, $jsonError("Invalid API key")

template requireUsername*(name: string) =
  if not isValidUsername(name):
    resp Http400, jsonHeaders, $jsonError("Invalid username")

proc createApiRouter*(cfg: Config) =
  router apiRoute:
    get "/api/capabilities":
      requireApi(request)
      let node = %*{
        "apiVersion": apiVersion,
        "instance": cfg.hostname,
        "authRequired": apiKey.len > 0,
        "endpoints": @[
          "/api/user/:name",
          "/api/user/:name/posts",
          "/api/user/:name/replies",
          "/api/user/:name/media",
          "/api/user/:name/articles",
          "/api/post/:id",
          "/api/search/posts"
        ],
        "features": @[
          "canonical-x-urls",
          "cursor-pagination",
          "media-variants",
          "article-timelines",
          "provenance-metadata",
          "string-snowflake-ids"
        ]
      }
      resp Http200, jsonHeaders, $node

    get "/api/user/@name":
      requireApi(request)
      let name = @"name"
      requireUsername(name)

      let user = await getCachedUser(name)
      if user.id.len == 0 and not user.suspended:
        resp Http404, jsonHeaders, $jsonError("User not found")

      var node = userToJson(user)
      node["provenance"] = provenanceToJson(toTwitterUserUrl(user), "user")
      resp Http200, jsonHeaders, $node

    get "/api/user/@name/@kind":
      requireApi(request)
      let
        name = @"name"
        kind = @"kind"
      requireUsername(name)
      if kind notin ["posts", "replies", "media", "articles"]:
        resp Http404, jsonHeaders, $jsonError("API endpoint not found")

      let
        cursor = getCursor()
        timelineKind = case kind
          of "replies": TimelineKind.replies
          of "media": TimelineKind.media
          of "articles": TimelineKind.articles
          else: TimelineKind.tweets
        userId = await getUserId(name)

      if userId.len == 0:
        resp Http404, jsonHeaders, $jsonError("User not found")
      if userId == "suspended":
        resp Http404, jsonHeaders, $jsonError("User is suspended")

      var profile = await getGraphUserTweets(userId, timelineKind, cursor)
      profile.user = await getCachedUser(name)

      var node = timelineToJson(profile.tweets, "user-" & kind)
      node["user"] = userToJson(profile.user)
      node["provenance"]["canonicalUrl"] = %toTwitterUserUrl(profile.user)
      resp Http200, jsonHeaders, $node

    get "/api/post/@id":
      requireApi(request)
      let id = @"id"
      if not isValidTweetId(id):
        resp Http400, jsonHeaders, $jsonError("Invalid post ID")

      let conv = await getTweet(id, getCursor())
      if conv == nil or conv.tweet == nil or conv.tweet.id == 0:
        resp Http404, jsonHeaders, $jsonError("Post not found")

      var replyItems = newJArray()
      for chain in conv.replies.content:
        replyItems.add %*{
          "items": tweetsToJson(chain.content),
          "hasMore": chain.hasMore,
          "cursor": chain.cursor
        }

      let node = %*{
        "tweet": tweetToJson(conv.tweet),
        "before": %*{
          "items": tweetsToJson(conv.before.content),
          "hasMore": conv.before.hasMore,
          "cursor": conv.before.cursor
        },
        "after": %*{
          "items": tweetsToJson(conv.after.content),
          "hasMore": conv.after.hasMore,
          "cursor": conv.after.cursor
        },
        "replies": %*{
          "items": replyItems,
          "nextCursor": conv.replies.bottom,
          "previousCursor": conv.replies.top,
          "beginning": conv.replies.beginning
        },
        "provenance": provenanceToJson(toTwitterStatusUrl(conv.tweet), "conversation")
      }
      resp Http200, jsonHeaders, $node

    get "/api/search/posts":
      requireApi(request)
      if @"q".len == 0:
        resp Http400, jsonHeaders, $jsonError("Missing q parameter")
      if @"q".len > 500:
        resp Http400, jsonHeaders, $jsonError("Search input too long")

      var queryParams = params(request)
      queryParams["f"] = "tweets"
      let query = initQuery(queryParams)

      let node = await postSearchToJson(query, getCursor())
      resp Http200, jsonHeaders, $node

    post "/api/search/posts":
      requireApi(request)
      let body = request.body
      if body.len == 0:
        resp Http400, jsonHeaders, $jsonError("Missing JSON body")

      var js: JsonNode
      try:
        js = parseJson(body)
      except JsonParsingError:
        resp Http400, jsonHeaders, $jsonError("Invalid JSON body")

      if js.kind != JObject:
        resp Http400, jsonHeaders, $jsonError("Invalid JSON body")

      let q = js{"q"}.getStr
      if q.len == 0:
        resp Http400, jsonHeaders, $jsonError("Missing q parameter")
      if q.len > 500:
        resp Http400, jsonHeaders, $jsonError("Search input too long")

      let node = await postSearchToJson(Query(kind: tweets, text: q), js{"cursor"}.getStr)
      resp Http200, jsonHeaders, $node
