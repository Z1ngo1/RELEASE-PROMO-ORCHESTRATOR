"""
app.py - Flask front-end for RELSMGR / PROMGR / EVTMGR / CLASHRDR

Calls CICS Web Support directly over plain HTTP - GET with a query string,
POST with a form-encoded body - and the COBOL programs answer with JSON.
"""

from flask import Flask, render_template, request, jsonify
import requests

app = Flask(__name__)

BASE_URL = "http://s0w1.dal-ebis.ihost.com:4558"

RELSMGR_URL = f"{BASE_URL}/relsmgr"
PROMGR_URL = f"{BASE_URL}/promgr"
EVTMGR_URL = f"{BASE_URL}/evtmgr"
CLASHRDR_URL = f"{BASE_URL}/clashrdr"


def call_get(url, params=None):
    """GET request with a query string, e.g. ?id=REL1"""
    resp = requests.get(url, params=params, timeout=15)
    try:
        return resp.json()
    except ValueError:
        # CICS sends an HTML error page when the transaction abends.
        # Turn that into a normal error dict instead of letting it crash.
        return {"error": f"Non-JSON response from mainframe (HTTP {resp.status_code})",
                "raw": resp.text[:300]}


def call_post(url, data=None):
    """POST request with a form-encoded body, e.g. title=My+Show&genre=DRAMA"""
    resp = requests.post(url, data=data, timeout=15)
    try:
        return resp.json()
    except ValueError:
        return {"error": f"Non-JSON response from mainframe (HTTP {resp.status_code})",
                "raw": resp.text[:300]}


def result_or_error(result, status_ok=200):
    """Turns a call_get/call_post result into a Flask response with the
    right status code, so a mainframe error actually shows up as an
    error on the frontend instead of looking like a success."""
    if isinstance(result, dict) and result.get("error"):
        return jsonify(result), 502
    return jsonify(result), status_ok


def as_list(result):
    """LST can come back as a dict, a list, or empty ({} / [])."""
    if isinstance(result, dict):
        return [result] if result else []
    return result or []


def normalize_release(rec):
    return {
        "id": rec.get("releaseId", ""),
        "title": rec.get("title", ""),
        "genre": rec.get("genre", ""),
        "platform": rec.get("platform", ""),
        "releaseDate": rec.get("releaseDate", ""),
        "windowEnd": rec.get("windowEnd", ""),
        "market": rec.get("targetMarket", ""),
        "status": rec.get("status", ""),
    }


def normalize_promo(rec):
    return {
        "id": rec.get("promoId", ""),
        "releaseId": rec.get("releaseId", ""),
        "itemName": rec.get("itemName", ""),
        "status": rec.get("status", ""),
        "dueDate": rec.get("dueDate", ""),
        "owner": rec.get("owner", ""),
    }


def normalize_event(rec):
    return {
        "id": rec.get("eventId", ""),
        "name": rec.get("eventName", ""),
        "date": rec.get("eventDate", ""),
        "end": rec.get("eventEnd", ""),
        "genre": rec.get("impactGenre", ""),
        "market": rec.get("impactMarket", ""),
        "severity": rec.get("severity", ""),
    }


def normalize_clash(rec):
    return {
        "id": rec.get("scoreId", ""),
        "releaseId": rec.get("releaseId", ""),
        "clashWithId": rec.get("clashWithId", ""),
        "riskScore": rec.get("riskScore", ""),
        "factors": rec.get("scoreFactors", ""),
        "scoredTs": rec.get("scoredTs", ""),
    }


def get_dashboard_data():
    """Pulls and normalizes data from all four services. Used by both the
    page route and the JSON refresh endpoint so they can't drift apart."""
    error = None
    promo_error = None
    clash_error = None
    evt_error = None

    try:
        result = call_get(f"{RELSMGR_URL}/list")
        if isinstance(result, dict) and result.get("error"):
            releases, error = [], result["error"]
        else:
            releases = [normalize_release(r) for r in as_list(result)]
    except requests.RequestException as e:
        releases, error = [], f"relsmgrService: {e}"

    promos = []
    clashes = []
    for r in releases:
        rel_id = r["id"]
        if not rel_id:
            continue
        try:
            result = call_get(f"{PROMGR_URL}/list", params={"relId": rel_id})
            if isinstance(result, dict) and result.get("error"):
                promo_error = result["error"]
            else:
                promos.extend(normalize_promo(p) for p in as_list(result))
        except requests.RequestException as e:
            promo_error = str(e)
        try:
            result = call_get(f"{CLASHRDR_URL}/get", params={"id": rel_id})
            if isinstance(result, dict) and result.get("error"):
                clash_error = result["error"]
            else:
                clashes.extend(normalize_clash(c) for c in as_list(result))
        except requests.RequestException as e:
            clash_error = str(e)

    try:
        result = call_get(f"{EVTMGR_URL}/list")
        if isinstance(result, dict) and result.get("error"):
            events, evt_error = [], result["error"]
        else:
            events = [normalize_event(e) for e in as_list(result)]
    except requests.RequestException as e:
        events, evt_error = [], str(e)

    return {
        "releases": releases,
        "error": error,
        "promos": promos,
        "promo_error": promo_error,
        "events": events,
        "evt_error": evt_error,
        "clashes": clashes,
        "clash_error": clash_error,
    }


@app.route("/")
def index():
    return render_template("release_radar.html", **get_dashboard_data())


@app.route("/api/dashboard")
def api_dashboard():
    """Same data as the page route, as JSON. Used for auto-refresh
    without reloading the whole page."""
    return jsonify(get_dashboard_data())


# ---------------- RELSMGR ----------------

@app.route("/api/release/<release_id>")
def get_release(release_id):
    try:
        result = call_get(f"{RELSMGR_URL}/get", params={"id": release_id})
    except requests.RequestException as e:
        return jsonify({"error": str(e)}), 502
    if isinstance(result, dict) and result.get("error"):
        return result_or_error(result)
    return jsonify(normalize_release(result))


@app.route("/api/release", methods=["POST"])
def add_release():
    body = request.get_json(force=True)
    try:
        result = call_post(f"{RELSMGR_URL}/add", data={
            "title": body.get("title", ""),
            "genre": body.get("genre", ""),
            "platform": body.get("platform", ""),
            "releaseDate": body.get("releaseDate", ""),
            "windowEnd": body.get("windowEnd", ""),
            "market": body.get("market", ""),
        })
    except requests.RequestException as e:
        return jsonify({"error": str(e)}), 502
    return result_or_error(result)


@app.route("/api/release/<release_id>", methods=["PUT"])
def update_release(release_id):
    body = request.get_json(force=True)
    try:
        result = call_post(f"{RELSMGR_URL}/upd", data={
            "id": release_id,
            "status": body.get("status", ""),
            "title": body.get("title", ""),
            "genre": body.get("genre", ""),
            "platform": body.get("platform", ""),
            "releaseDate": body.get("releaseDate", ""),
            "windowEnd": body.get("windowEnd", ""),
            "market": body.get("market", ""),
        })
    except requests.RequestException as e:
        return jsonify({"error": str(e)}), 502
    return result_or_error(result)


@app.route("/api/release/<release_id>", methods=["DELETE"])
def delete_release(release_id):
    try:
        result = call_post(f"{RELSMGR_URL}/del", data={"id": release_id})
    except requests.RequestException as e:
        return jsonify({"error": str(e)}), 502
    return result_or_error(result)


# ---------------- PROMGR ----------------

@app.route("/api/promo/<promo_id>")
def get_promo(promo_id):
    try:
        result = call_get(f"{PROMGR_URL}/get", params={"id": promo_id})
    except requests.RequestException as e:
        return jsonify({"error": str(e)}), 502
    if isinstance(result, dict) and result.get("error"):
        return result_or_error(result)
    return jsonify(normalize_promo(result))


@app.route("/api/promo", methods=["POST"])
def add_promo():
    body = request.get_json(force=True)
    try:
        result = call_post(f"{PROMGR_URL}/add", data={
            "relId": body.get("relId", ""),
            "itemName": body.get("itemName", ""),
            "status": body.get("status", ""),
            "dueDate": body.get("dueDate", ""),
            "owner": body.get("owner", ""),
        })
    except requests.RequestException as e:
        return jsonify({"error": str(e)}), 502
    return result_or_error(result)


@app.route("/api/promo/<promo_id>", methods=["PUT"])
def update_promo(promo_id):
    body = request.get_json(force=True)
    try:
        result = call_post(f"{PROMGR_URL}/upd", data={
            "id": promo_id,
            "itemName": body.get("itemName", ""),
            "status": body.get("status", ""),
            "dueDate": body.get("dueDate", ""),
            "owner": body.get("owner", ""),
        })
    except requests.RequestException as e:
        return jsonify({"error": str(e)}), 502
    return result_or_error(result)


@app.route("/api/promo/<promo_id>", methods=["DELETE"])
def delete_promo(promo_id):
    try:
        result = call_post(f"{PROMGR_URL}/del", data={"id": promo_id})
    except requests.RequestException as e:
        return jsonify({"error": str(e)}), 502
    return result_or_error(result)


# ---------------- EVTMGR ----------------

@app.route("/api/event/<evt_id>")
def get_event(evt_id):
    try:
        result = call_get(f"{EVTMGR_URL}/get", params={"id": evt_id})
    except requests.RequestException as e:
        return jsonify({"error": str(e)}), 502
    if isinstance(result, dict) and result.get("error"):
        return result_or_error(result)
    return jsonify(normalize_event(result))


@app.route("/api/event", methods=["POST"])
def add_event():
    body = request.get_json(force=True)
    try:
        result = call_post(f"{EVTMGR_URL}/add", data={
            "evtName": body.get("evtName", ""),
            "evtDate": body.get("evtDate", ""),
            "evtEnd": body.get("evtEnd", ""),
            "genre": body.get("genre", ""),
            "market": body.get("market", ""),
            "severity": body.get("severity", ""),
        })
    except requests.RequestException as e:
        return jsonify({"error": str(e)}), 502
    return result_or_error(result)


@app.route("/api/event/<evt_id>", methods=["PUT"])
def update_event(evt_id):
    body = request.get_json(force=True)
    try:
        result = call_post(f"{EVTMGR_URL}/upd", data={
            "id": evt_id,
            "evtName": body.get("evtName", ""),
            "evtDate": body.get("evtDate", ""),
            "evtEnd": body.get("evtEnd", ""),
            "genre": body.get("genre", ""),
            "market": body.get("market", ""),
            "severity": body.get("severity", ""),
        })
    except requests.RequestException as e:
        return jsonify({"error": str(e)}), 502
    return result_or_error(result)


@app.route("/api/event/<evt_id>", methods=["DELETE"])
def delete_event(evt_id):
    try:
        result = call_post(f"{EVTMGR_URL}/del", data={"id": evt_id})
    except requests.RequestException as e:
        return jsonify({"error": str(e)}), 502
    return result_or_error(result)


# ---------------- CLASHRDR (read-only) ----------------

@app.route("/api/clash/<release_id>")
def get_clash(release_id):
    try:
        result = call_get(f"{CLASHRDR_URL}/get", params={"id": release_id})
    except requests.RequestException as e:
        return jsonify({"error": str(e)}), 502
    if isinstance(result, dict) and result.get("error"):
        return result_or_error(result)
    return jsonify([normalize_clash(c) for c in as_list(result)])


if __name__ == "__main__":
    app.run(host="204.90.115.200", port=0)
