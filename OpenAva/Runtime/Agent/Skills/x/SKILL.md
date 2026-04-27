---
name: x
description: Look up X profiles, posts, followers, and following using `x_query`, and manage stored credentials with `x_auth`.
when_to_use: Use when the user asks for X account lookups, post search, profile timelines, followers/following inspection, or when authenticated X access is more reliable than generic web search.
allowed-tools:
  - x_query
  - x_auth
  - web_search
  - web_fetch
metadata:
  display_name: X
---

# X

Use this skill when the task is specifically about X content or account graphs and you want structured results from the authenticated web GraphQL endpoints instead of only scraping public web pages.

## What this skill is good for

- search recent or top tweets for a topic
- fetch a user's profile data
- fetch a user's own tweet timeline
- inspect followers or following with cursor pagination
- switch between stored credentials and inline credentials when needed

## Recommended workflow

1. If the task needs authenticated X data and credentials may not be configured yet, call `x_auth` with `action: "status"` first.
2. If credentials are missing and the user has provided `auth_token` and optionally `ct0` / bearer, save them with `x_auth` using `action: "set"`.
3. Use `x_query` with exactly one operation at a time:
   - `user_profiles` for one or more usernames
   - `profile_tweets` for a single target user timeline
   - `followers` / `following` for graph traversal
   - `search_tweets` for topic or keyword discovery
4. For `profile_tweets`, `followers`, and `following`, prefer `username` unless you already have a `userId`.
5. For `search_tweets`, start with `maxResults: 10` to `20`, then follow `nextCursor` only if the user wants deeper coverage.
6. When the returned data is insufficient or the user needs page-level context, follow up with `web_fetch` on a tweet URL or profile URL.

## Search guidance

Prefer `search_tweets` in these cases:

- the user asks what people are saying about a topic
- the user wants recent posts from multiple accounts
- the user wants structured filters like:
  - `fromUsers`
  - `exactPhrases`
  - `hashtagsAny`
  - `tweetType`
  - `minLikes`
  - `since` / `until`

Useful `tweetType` values:

- `all`
- `originals_only`
- `replies_only`
- `retweets_only`
- `exclude_replies`
- `exclude_retweets`

Use `displayType: "latest"` for recent coverage and `displayType: "top"` for more ranked results.

## Pagination guidance

- `followers`, `following`, `profile_tweets`, and `search_tweets` may return `nextCursor`
- only continue pagination when the user actually needs more than the first page
- mention when the result is only the first page of a larger set

## Credential guidance

- Stored credentials are preferred for repeated use in a session.
- Inline `auth` is useful when the user wants a one-off request without persisting secrets.
- If only `authToken` is available, `x_auth` may be able to bootstrap `ct0` automatically.
- Do not expose or repeat secrets back to the user.

## Fallback guidance

If X credentials are unavailable or the API is rate limited:

1. Say clearly that authenticated X access is unavailable.
2. Fall back to `web_search` for public discoverability.
3. Use `web_fetch` only on the most promising result pages.
4. Call out the lower confidence of the fallback path.

## Output discipline

Prefer concise structured summaries:

- **Profiles**: username, name, bio, follower/following counts, verification, profile URL
- **Tweets**: author, timestamp, text, engagement counts, tweet URL
- **Followers / Following**: count returned, notable accounts, whether more pages remain
- **Search**: query used, result count, top tweets, notable accounts, next cursor availability

Do not claim coverage beyond the returned page unless you actually paginated further.
