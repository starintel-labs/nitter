import json
from urllib.parse import quote, urlparse
from urllib.request import Request, urlopen


VIDEO_TWEET_ID = "1078373829917974528"
USER_NAME = "OpenAI"
SEARCH_QUERY = "from:OpenAI"
SEARCH_QUERY_ENCODED = quote(SEARCH_QUERY, safe="")
BASE_URL = "http://localhost:8080"
URL_FIELDS = {"url", "avatar", "banner", "thumbnail", "canonicalUrl", "coverImage"}
ALLOWED_URL_HOSTS = {"x.com", "pbs.twimg.com", "video.twimg.com"}


def fetch_json(path):
    with urlopen(f"{BASE_URL}{path}") as response:
        assert response.status == 200
        return json.loads(response.read().decode("utf-8"))


def post_json(path, payload):
    request = Request(
        f"{BASE_URL}{path}",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urlopen(request) as response:
        assert response.status == 200
        return json.loads(response.read().decode("utf-8"))


def assert_absolute_urls(node):
    if isinstance(node, dict):
        for key, value in node.items():
            if key in URL_FIELDS and isinstance(value, str) and value:
                if key == "banner" and value.startswith("#"):
                    continue
                parsed = urlparse(value)
                assert parsed.scheme == "https", (key, value)
                assert parsed.netloc in ALLOWED_URL_HOSTS, (key, value)
            assert_absolute_urls(value)
    elif isinstance(node, list):
        for item in node:
            assert_absolute_urls(item)


def test_capabilities_describe_starintel_surface():
    payload = fetch_json("/api/capabilities")
    assert payload["apiVersion"] == "starintel-nitter/v1"
    assert "/api/user/:name/articles" in payload["endpoints"]
    assert "provenance-metadata" in payload["features"]
    assert "string-snowflake-ids" in payload["features"]


def test_post_video_media_has_url_variants_and_provenance():
    payload = fetch_json(f"/api/post/{VIDEO_TWEET_ID}")
    tweet = payload["tweet"]
    media = tweet["media"]
    videos = [item for item in media if item["type"] == "video"]

    assert tweet["provenance"]["collector"] == "starintel-labs/nitter"
    assert tweet["provenance"]["canonicalUrl"] == tweet["url"]
    assert videos

    video = videos[0]
    variants = video["variants"]
    assert video["url"]
    assert video["thumbnail"]
    assert variants
    assert video["url"] in {variant["url"] for variant in variants}
    assert any(variant["contentType"] == video["playbackType"] for variant in variants)


def test_post_payload_uses_absolute_urls():
    payload = fetch_json(f"/api/post/{VIDEO_TWEET_ID}")
    assert_absolute_urls(payload)


def test_user_payload_uses_absolute_urls_and_string_id():
    payload = fetch_json(f"/api/user/{USER_NAME}")
    assert isinstance(payload["id"], str)
    assert payload["provenance"]["resource"] == "user"
    assert_absolute_urls(payload)


def test_user_posts_payload_has_cursor_shape():
    payload = fetch_json(f"/api/user/{USER_NAME}/posts")
    assert payload["items"]
    assert "nextCursor" in payload
    assert "previousCursor" in payload
    assert_absolute_urls(payload)


def test_search_get_payload_uses_absolute_urls():
    payload = fetch_json(f"/api/search/posts?q={SEARCH_QUERY_ENCODED}")
    assert payload["items"]
    assert payload["query"] == SEARCH_QUERY
    assert_absolute_urls(payload)


def test_search_post_payload_uses_absolute_urls():
    payload = post_json("/api/search/posts", {"q": SEARCH_QUERY})
    assert payload["items"]
    assert_absolute_urls(payload)
