#!/usr/bin/env python3
"""Sets Jelly up in App Store Connect from the files in AppStore/ – once the app record exists, which Apple only lets
people create in the browser. Every step looks first and only creates or changes what is missing, so it can run again.

Usage: asc_appstore.py KEY_ID ISSUER_ID KEY_PATH setup             texts, screenshots, age rating, price, availability,
                                                                      subscription with free trial, App Review details
       asc_appstore.py KEY_ID ISSUER_ID KEY_PATH attach BUILDNUMBER  puts an uploaded, processed build on version 1.0
       asc_appstore.py KEY_ID ISSUER_ID KEY_PATH submit --yes       sends version and subscription to App Review
App Review contact (seen by Apple only, never committed): REVIEW_FIRST_NAME, REVIEW_LAST_NAME, REVIEW_PHONE, REVIEW_EMAIL.
"""
import hashlib, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from asc_api import call, configure, pages, query, upload  # noqa: E402

if len(sys.argv) < 5:
    sys.exit(__doc__)
KEY_ID, ISSUER, KEY_PATH, COMMAND = sys.argv[1:5]
configure(KEY_ID, ISSUER, KEY_PATH)

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "AppStore")
BUNDLE_ID = os.environ.get("BUNDLE_ID", "net.dgtl24.jelly")
LOCALE = "de-DE"
SUBSCRIPTION_ID = f"{BUNDLE_ID}.yearly"
PRICE = "9.99"
BASE_TERRITORY = "DEU"
SCREENSHOTS = ["1-start.png", "2-details.png", "3-player.png", "4-info.png"]


def text(name):
    with open(os.path.join(ROOT, name), encoding="utf-8") as file:
        return file.read().strip()


def meta(name):
    return text(os.path.join("metadata", LOCALE, name))


def ref(kind, identifier):
    return {"data": {"type": kind, "id": identifier}}


def step(title):
    print(f"• {title}")


def put_asset(create_path, kind, relationship, owner_kind, owner_id, path):
    """Reserves an asset (screenshot), uploads the bytes and commits it with its checksum."""
    data = open(path, "rb").read()
    reserved = call("POST", create_path, {"data": {"type": kind, "attributes": {"fileName": os.path.basename(path), "fileSize": len(data)},
                                               "relationships": {relationship: ref(owner_kind, owner_id)}}})["data"]
    upload(reserved["attributes"]["uploadOperations"], data)
    call("PATCH", f"{create_path}/{reserved['id']}", {"data": {"type": kind, "id": reserved["id"], "attributes": {
        "uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})


apps = [a for a in call("GET", query("/apps", bundleId=BUNDLE_ID))["data"] if a["attributes"]["bundleId"] == BUNDLE_ID]
if not apps:
    sys.exit(f"Keine App mit der Bundle-ID {BUNDLE_ID} in App Store Connect. Erst im Browser anlegen: Apps › + › Neue App "
             f"(tvOS, Name „Jelly“, Primärsprache Deutsch, Bundle-ID {BUNDLE_ID}, SKU jelly-tvos).")
app = apps[0]["id"]
versions = [v for v in call("GET", f"/apps/{app}/appStoreVersions?filter[platform]=TV_OS&limit=10")["data"]
            if v["attributes"]["appStoreState"] in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED")]
if not versions:
    sys.exit("Keine bearbeitbare tvOS-Version gefunden.")
version = versions[0]["id"]
territories = [t["id"] for t in pages("/territories?limit=200")[0]]

if COMMAND == "setup":
    step("App-Infos: Name, Untertitel, Datenschutz, Kategorie, Altersfreigabe")
    info = call("GET", f"/apps/{app}/appInfos")["data"][0]["id"]
    for loc in call("GET", f"/appInfos/{info}/appInfoLocalizations")["data"]:
        if loc["attributes"]["locale"] == LOCALE:
            call("PATCH", f"/appInfoLocalizations/{loc['id']}", {"data": {"type": "appInfoLocalizations", "id": loc["id"], "attributes": {
                "name": meta("name.txt"), "subtitle": meta("subtitle.txt"), "privacyPolicyUrl": meta("privacy_url.txt")}}}, fatal=False)
    call("PATCH", f"/appInfos/{info}", {"data": {"type": "appInfos", "id": info, "relationships": {
        "primaryCategory": ref("appCategories", "ENTERTAINMENT")}}}, fatal=False)
    rating = call("GET", f"/appInfos/{info}/ageRatingDeclaration")["data"]["id"]
    none = {k: "NONE" for k in ["alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated", "gunsOrOtherWeapons",
                                 "medicalOrTreatmentInformation", "profanityOrCrudeHumor", "sexualContentGraphicAndNudity",
                                 "sexualContentOrNudity", "horrorOrFearThemes", "matureOrSuggestiveThemes", "violenceCartoonOrFantasy",
                                 "violenceRealisticProlongedGraphicOrSadistic", "violenceRealistic"]}
    no = {k: False for k in ["advertising", "gambling", "healthOrWellnessTopics", "lootBox", "messagingAndChat", "parentalControls",
                             "ageAssurance", "socialMedia", "unrestrictedWebAccess", "userGeneratedContent"]}
    call("PATCH", f"/ageRatingDeclarations/{rating}", {"data": {"type": "ageRatingDeclarations", "id": rating, "attributes": {**none, **no}}},
         fatal=False)

    step("Version 1.0: Copyright, Beschreibung, Stichwörter, Werbetext, Support-Seite")
    call("PATCH", f"/appStoreVersions/{version}", {"data": {"type": "appStoreVersions", "id": version, "attributes": {
        "copyright": "2026 DGTL Solutions GmbH"}}}, fatal=False)
    localization = next(l for l in call("GET", f"/appStoreVersions/{version}/appStoreVersionLocalizations")["data"]
                        if l["attributes"]["locale"] == LOCALE)["id"]
    call("PATCH", f"/appStoreVersionLocalizations/{localization}", {"data": {"type": "appStoreVersionLocalizations", "id": localization,
         "attributes": {"description": meta("description.txt"), "keywords": meta("keywords.txt"), "promotionalText": meta("promotional_text.txt"),
                        "supportUrl": meta("support_url.txt"), "marketingUrl": "https://dgtl-solutions.github.io/jelly/"}}}, fatal=False)

    step("Screenshots (Apple TV, 1920×1080)")
    sets = call("GET", f"/appStoreVersionLocalizations/{localization}/appScreenshotSets?include=appScreenshots")
    tv = next((s for s in sets["data"] if s["attributes"]["screenshotDisplayType"] == "APP_APPLE_TV"), None)
    if tv is None:
        tv = call("POST", "/appScreenshotSets", {"data": {"type": "appScreenshotSets", "attributes": {"screenshotDisplayType": "APP_APPLE_TV"},
                  "relationships": {"appStoreVersionLocalization": ref("appStoreVersionLocalizations", localization)}}})["data"]
    present = {s["attributes"]["fileName"] for s in sets.get("included", []) if s["type"] == "appScreenshots"}
    for name in SCREENSHOTS:
        if name not in present:
            put_asset("/appScreenshots", "appScreenshots", "appScreenshotSet", "appScreenshotSets", tv["id"], os.path.join(ROOT, "screenshots", name))
            print(f"  hochgeladen: {name}")

    step("App-Review-Angaben")
    contact = {k: os.environ.get(v) for k, v in [("contactFirstName", "REVIEW_FIRST_NAME"), ("contactLastName", "REVIEW_LAST_NAME"),
                                                 ("contactPhone", "REVIEW_PHONE"), ("contactEmail", "REVIEW_EMAIL")] if os.environ.get(v)}
    review = {**contact, "demoAccountRequired": False, "notes": text("review-notes.txt")[:4000]}
    existing = call("GET", f"/appStoreVersions/{version}/appStoreReviewDetail", fatal=False)
    if existing and existing.get("data"):
        call("PATCH", f"/appStoreReviewDetails/{existing['data']['id']}", {"data": {"type": "appStoreReviewDetails",
             "id": existing["data"]["id"], "attributes": review}}, fatal=False)
    else:
        call("POST", "/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails", "attributes": review,
             "relationships": {"appStoreVersion": ref("appStoreVersions", version)}}}, fatal=False)
    if len(contact) < 4:
        print("  ! Kontakt für App Review fehlt noch (REVIEW_FIRST_NAME, REVIEW_LAST_NAME, REVIEW_PHONE, REVIEW_EMAIL).")

    step("Preis: gratis (freigeschaltet wird per Abo)")
    schedule = call("GET", f"/apps/{app}/appPriceSchedule?include=manualPrices", fatal=False)
    if not (schedule and schedule.get("included")):
        free = next(p for p in pages(f"/apps/{app}/appPricePoints?filter[territory]={BASE_TERRITORY}&limit=200")[0]
                    if float(p["attributes"]["customerPrice"]) == 0)
        call("POST", "/appPriceSchedules", {"data": {"type": "appPriceSchedules", "relationships": {
            "app": ref("apps", app), "baseTerritory": ref("territories", BASE_TERRITORY),
            "manualPrices": {"data": [{"type": "appPrices", "id": "${free}"}]}}},
            "included": [{"type": "appPrices", "id": "${free}", "attributes": {"startDate": None},
                          "relationships": {"appPricePoint": ref("appPricePoints", free["id"])}}]}, fatal=False)

    step("Verfügbarkeit: alle Länder")
    if not call("GET", f"/apps/{app}/appAvailabilityV2", fatal=False):
        body = {"data": {"type": "appAvailabilities", "attributes": {"availableInNewTerritories": True}, "relationships": {
            "app": ref("apps", app),
            "territoryAvailabilities": {"data": [{"type": "territoryAvailabilities", "id": f"${{{t}}}"} for t in territories]}}},
            "included": [{"type": "territoryAvailabilities", "id": f"${{{t}}}", "attributes": {"available": True},
                          "relationships": {"territory": ref("territories", t)}} for t in territories]}
        call("POST", "https://api.appstoreconnect.apple.com/v2/appAvailabilities", body, fatal=False)

    step("Abo-Gruppe „Jelly“ und Jahresabo")
    groups = call("GET", f"/apps/{app}/subscriptionGroups?limit=50")["data"]
    group = next((g["id"] for g in groups if g["attributes"]["referenceName"] == "Jelly"), None)
    if group is None:
        group = call("POST", "/subscriptionGroups", {"data": {"type": "subscriptionGroups", "attributes": {"referenceName": "Jelly"},
                     "relationships": {"app": ref("apps", app)}}})["data"]["id"]
    if not call("GET", f"/subscriptionGroups/{group}/subscriptionGroupLocalizations")["data"]:
        call("POST", "/subscriptionGroupLocalizations", {"data": {"type": "subscriptionGroupLocalizations",
             "attributes": {"name": "Jelly", "locale": LOCALE}, "relationships": {"subscriptionGroup": ref("subscriptionGroups", group)}}}, fatal=False)
    subscriptions = call("GET", f"/subscriptionGroups/{group}/subscriptions?limit=50")["data"]
    subscription = next((s["id"] for s in subscriptions if s["attributes"]["productId"] == SUBSCRIPTION_ID), None)
    if subscription is None:
        subscription = call("POST", "/subscriptions", {"data": {"type": "subscriptions", "attributes": {
            "name": "Jelly Jahresabo", "productId": SUBSCRIPTION_ID, "subscriptionPeriod": "ONE_YEAR", "familySharable": False,
            "groupLevel": 1, "reviewNote": "Unlocks playback for one year; new subscribers get a 2-week free trial. Offer screen: "
            "after sign-in or when pressing play; Settings › Jahresabo shows status and restore."},
            "relationships": {"group": ref("subscriptionGroups", group)}}})["data"]["id"]
    if not call("GET", f"/subscriptions/{subscription}/subscriptionLocalizations")["data"]:
        call("POST", "/subscriptionLocalizations", {"data": {"type": "subscriptionLocalizations", "attributes": {
            "name": "Jelly Jahresabo", "locale": LOCALE, "description": "Alle Funktionen von Jelly, ein Jahr lang"},
            "relationships": {"subscription": ref("subscriptions", subscription)}}}, fatal=False)
    if not call("GET", f"/subscriptions/{subscription}/subscriptionAvailability", fatal=False):
        call("POST", "/subscriptionAvailabilities", {"data": {"type": "subscriptionAvailabilities", "attributes": {"availableInNewTerritories": True},
             "relationships": {"subscription": ref("subscriptions", subscription),
                               "availableTerritories": {"data": [{"type": "territories", "id": t} for t in territories]}}}}, fatal=False)

    step(f"Abo-Preis: {PRICE.replace('.', ',')} € in Deutschland, andere Länder von Apple umgerechnet")
    if not call("GET", f"/subscriptions/{subscription}/prices?limit=1")["data"]:
        points, _ = pages(f"/subscriptions/{subscription}/pricePoints?filter[territory]={BASE_TERRITORY}&limit=200")
        base = next(p for p in points if float(p["attributes"]["customerPrice"]) == float(PRICE))
        equal, _ = pages(f"/subscriptionPricePoints/{base['id']}/equalizations?include=territory&limit=200")
        for point in [base] + equal:
            territory = point.get("relationships", {}).get("territory", {}).get("data", {}).get("id", BASE_TERRITORY)
            call("POST", "/subscriptionPrices", {"data": {"type": "subscriptionPrices", "attributes": {"startDate": None, "preserveCurrentPrice": False},
                 "relationships": {"subscription": ref("subscriptions", subscription), "territory": ref("territories", territory),
                                   "subscriptionPricePoint": ref("subscriptionPricePoints", point["id"])}}}, fatal=False)
        print(f"  Preise für {len(equal) + 1} Länder gesetzt")

    step("Einführungsangebot: 2 Wochen gratis für neue Abonnenten")
    if not call("GET", f"/subscriptions/{subscription}/introductoryOffers?limit=1")["data"]:
        for territory in territories:
            call("POST", "/subscriptionIntroductoryOffers", {"data": {"type": "subscriptionIntroductoryOffers", "attributes": {
                "duration": "TWO_WEEKS", "offerMode": "FREE_TRIAL", "numberOfPeriods": 1},
                "relationships": {"subscription": ref("subscriptions", subscription), "territory": ref("territories", territory)}}}, fatal=False)

    step("Review-Screenshot des Abo-Angebots")
    if not call("GET", f"/subscriptions/{subscription}/appStoreReviewScreenshot", fatal=False):
        put_asset("/subscriptionAppStoreReviewScreenshots", "subscriptionAppStoreReviewScreenshots", "subscription", "subscriptions",
                  subscription, os.path.join(ROOT, "screenshots", "iap-review-angebot.png"))
    print("Fertig. Fehlt nur noch der Build: Scripts/release-appstore.sh, dann „attach <Build-Nummer>“.")

elif COMMAND == "attach":
    number = sys.argv[5]
    builds = call("GET", f"/builds?filter[app]={app}&filter[version]={number}&limit=5")["data"]
    if not builds:
        sys.exit(f"Build {number} ist (noch) nicht da – die Verarbeitung nach dem Hochladen dauert meist 10 bis 30 Minuten.")
    state = builds[0]["attributes"]["processingState"]
    if state != "VALID":
        sys.exit(f"Build {number} ist noch in Verarbeitung ({state}).")
    call("PATCH", f"/appStoreVersions/{version}/relationships/build", ref("builds", builds[0]["id"]))
    print(f"Build {number} hängt an Version 1.0.")

elif COMMAND == "submit":
    if "--yes" not in sys.argv:
        sys.exit("Einreichen nur mit --yes: danach prüft Apple, und die App kann ohne weiteres Zutun erscheinen.")
    groups = call("GET", f"/apps/{app}/subscriptionGroups?limit=50")["data"]
    for group in groups:
        for subscription in call("GET", f"/subscriptionGroups/{group['id']}/subscriptions?limit=50")["data"]:
            call("POST", "/subscriptionSubmissions", {"data": {"type": "subscriptionSubmissions",
                 "relationships": {"subscription": ref("subscriptions", subscription["id"])}}}, fatal=False)
    submission = call("POST", "/reviewSubmissions", {"data": {"type": "reviewSubmissions", "attributes": {"platform": "TV_OS"},
                      "relationships": {"app": ref("apps", app)}}})["data"]["id"]
    call("POST", "/reviewSubmissionItems", {"data": {"type": "reviewSubmissionItems", "relationships": {
        "reviewSubmission": ref("reviewSubmissions", submission), "appStoreVersion": ref("appStoreVersions", version)}}})
    call("PATCH", f"/reviewSubmissions/{submission}", {"data": {"type": "reviewSubmissions", "id": submission, "attributes": {"submitted": True}}})
    print("Eingereicht. Den Stand zeigt App Store Connect › App › Verlauf.")

else:
    sys.exit(__doc__)
