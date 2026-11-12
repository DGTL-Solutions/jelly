#!/usr/bin/env python3
"""Jelly's daily numbers from App Store Connect: running subscriptions and trials (with auto-renew on or off),
proceeds so far, and what the last reported day added.
  python3 Scripts/asc_numbers.py <Key-ID> <Issuer-ID> <Key-Datei>
Sales reports come a day late, the subscription state report one to two days late; missing days are named."""
import collections, csv, datetime, gzip, io, sys, urllib.error, urllib.parse, urllib.request

import asc_api
from asc_api import call

APP, VENDOR, FIRST_DAY = "6826379119", "94116847", datetime.date(2026, 10, 27)
STATE_REPORT = "App Store Subscription State Report Standard"

if len(sys.argv) < 4:
    sys.exit(__doc__)
asc_api.configure(*sys.argv[1:4])


def table(data):
    return list(csv.DictReader(io.StringIO(gzip.decompress(data).decode()), delimiter="\t"))


def sales(day, kind, version):
    query = urllib.parse.urlencode({"filter[frequency]": "DAILY", "filter[reportType]": kind, "filter[reportSubType]": "SUMMARY",
                                    "filter[vendorNumber]": VENDOR, "filter[reportDate]": day.isoformat(), "filter[version]": version})
    request = urllib.request.Request(f"{asc_api.API}/salesReports?{query}",
                                     headers={"Authorization": "Bearer " + asc_api.token(), "Accept": "application/a-gzip"})
    try:
        return table(urllib.request.urlopen(request).read())
    except urllib.error.HTTPError:
        return None  # no report for that day (yet)


# Running subscriptions: the newest two days of the state report.
states = {}
for request in call("GET", f"/apps/{APP}/analyticsReportRequests?filter[accessType]=ONGOING")["data"]:
    for report in call("GET", f"/analyticsReportRequests/{request['id']}/reports?filter[name]={urllib.parse.quote(STATE_REPORT)}")["data"]:
        instances = call("GET", f"/analyticsReports/{report['id']}/instances?filter[granularity]=DAILY&limit=200")["data"]
        for instance in sorted(instances, key=lambda i: i["attributes"]["processingDate"])[-2:]:
            for segment in call("GET", f"/analyticsReportInstances/{instance['id']}/segments")["data"]:
                for row in table(urllib.request.urlopen(segment["attributes"]["url"]).read()):
                    day = states.setdefault(row["Date"], collections.Counter())
                    # Later instances repeat earlier days; the newest one wins.
                    day[(instance["attributes"]["processingDate"], row["State Metric"], row["Auto-Renew Status"])] += int(row["Counts"])


def state(day):
    newest = max(key[0] for key in states[day])
    return {key[1:]: count for key, count in states[day].items() if key[0] == newest}


def state_line(day):
    counts = state(day)
    paid = sum(v for (metric, _), v in counts.items() if metric not in ("Free trial", "Voluntarily churned", "Involuntarily churned"))
    return {"bezahlt": paid, "Probe, Verlängerung an": counts.get(("Free trial", "Auto-renew on"), 0),
            "Probe, Verlängerung aus": counts.get(("Free trial", "Auto-renew off"), 0)}


days = sorted(states)[-2:]
if days:
    now, before = state_line(days[-1]), state_line(days[0])
    print(f"Laufende Abos (Stand {days[-1]}, Vergleich {days[0]}):")
    for name, count in now.items():
        print(f"  {name}: {count} ({count - before[name]:+d})")
else:
    print("Laufende Abos: kein Bericht verfügbar.")

# Proceeds so far and the last reported day.
proceeds, last, missing = collections.Counter(), None, []
day, yesterday = FIRST_DAY, datetime.date.today() - datetime.timedelta(days=1)
while day <= yesterday:
    rows = sales(day, "SALES", "1_0")
    if rows is None:
        missing.append(day.isoformat())
    else:
        today = {"Tag": day, "Erstinstallationen": 0, "neue Probezeiten": 0, "bezahlte Käufe": 0, "Erlös": collections.Counter()}
        for row in rows:
            kind, units, amount = row["Product Type Identifier"].strip(), int(float(row["Units"])), float(row["Developer Proceeds"])
            if kind in ("1", "1F", "1T", "F1"):
                today["Erstinstallationen"] += units
            elif kind.startswith(("IA", "FI")):
                if amount:
                    today["bezahlte Käufe"] += units
                    today["Erlös"][row["Currency of Proceeds"]] += units * amount
                    proceeds[row["Currency of Proceeds"]] += units * amount
                elif units > 0:
                    today["neue Probezeiten"] += units
        last = today
    day += datetime.timedelta(days=1)

money = lambda counter: ", ".join(f"{value:.2f} {currency}" for currency, value in sorted(counter.items())) or "0"
print(f"Erlös bisher (dein Anteil, seit {FIRST_DAY}): {money(proceeds)}")
if last:
    print(f"Dazugekommen am {last['Tag']}: {last['neue Probezeiten']} neue Probezeiten, {last['bezahlte Käufe']} bezahlte Käufe "
          f"({money(last['Erlös'])}), {last['Erstinstallationen']} Erstinstallationen")
if missing:
    print("Ohne Verkaufsbericht:", ", ".join(missing))
events = sales(last["Tag"], "SUBSCRIPTION_EVENT", "1_4") if last else None
if events:
    counts = collections.Counter()
    for row in events:
        counts[row["Event"]] += int(row["Quantity"])
    print("Abo-Ereignisse an dem Tag:", ", ".join(f"{name}: {count}" for name, count in sorted(counts.items())))
