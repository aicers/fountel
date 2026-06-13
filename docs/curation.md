# Curation policy and the `fountel:floor-eligible` taxonomy

fountel publishes an **additive** subset of MISP intel to aimer-web. This
document defines how that subset is curated and how the one curation signal
that crosses the wire — floor-eligibility — is represented.

## Soft-by-default

The governing rule is **soft-by-default**:

> Everything fountel publishes is treated as **soft** intel (LLM-enrichment
> input) **unless** the source has been explicitly vetted and its intel
> carries the `fountel:floor-eligible` tag.

Most additive feeds are noisy. Their value is *context that thickens
LLM analysis* (tags, classifications, multi-source corroboration, galaxies),
not deterministic verdicts. Treating them as soft by default keeps that noise
out of any deterministic/"floor" decision path on the consumer side. There is
no "more is better" pressure here: a tag is added only after a source earns it.

## The taxonomy

The signal is a dedicated MISP taxonomy, defined in
[`deploy/dev/taxonomies/fountel/machinetag.json`](../deploy/dev/taxonomies/fountel/machinetag.json):

- **Namespace:** `fountel`
- **Predicate:** `floor-eligible`
- **Resulting tag:** `fountel:floor-eligible`

A tagged event/attribute tells aimer-web it may set `floorEligible` on the
resulting match (deterministic-grade). The **absence** of the tag is the
default and means soft / LLM-enrichment only. This maps directly onto
aimer-web RFC 0003's deterministic-vs-soft hinge.

The taxonomy is `exclusive: false`, so the tag composes freely with other
MISP taxonomies and galaxies on the same event.

## How it gets loaded

`./deploy/dev/bin/bootstrap.sh` installs and enables the taxonomy
idempotently:

1. Copies `machinetag.json` into MISP's `files/taxonomies/fountel/`.
2. Runs `cake Admin updateTaxonomies` to import the definition.
3. Enables the taxonomy and creates its tag via the REST API.

Re-running it is a no-op. You can confirm it loaded in the UI under
**Event Actions → Taxonomies** (search `fountel`) or via the API:

```sh
curl -ks -H "Authorization: $ADMIN_KEY" -H "Accept: application/json" \
  https://localhost:8443/taxonomies/index | grep -Eo '"namespace": *"fountel"'
```

## Applying floor-eligibility (per-source vetting)

Floor-eligibility is granted **per source**, after review, never per
indicator and never by default:

1. Review the source (quality, false-positive rate, licensing for
   commercial product use).
2. If it clears review, tag its events/attributes with
   `fountel:floor-eligible` — typically via a publish-time tag/org filter so
   the decision is config-as-code, not manual per-event tagging.
3. Everything else stays untagged and therefore soft.

To revoke, remove the tag from the source's publish filter; the next publish
cycle drops the signal and aimer-web reverts those indicators to soft.

## Out of scope here

The publish-time filter, the feed-export job, and the mTLS gateway that
actually ships tagged intel to aimer-web are **not** part of this stack; they
are tracked separately. This document defines only the curation *convention*
and the taxonomy that encodes it.
