# TubeRemote Pro: what App Store Connect needs

App Store Connect > TubeRemote > Monetization > In-App Purchases > TubeRemote Pro.

| Field | Value |
| --- | --- |
| Type | Non-Consumable (already set) |
| Reference Name | TubeRemote Pro |
| Product ID | `com.exaltedpixels.TubeRemote.pro` (already set; the app looks for exactly this) |
| Price | Your choice. $4.99 USD is the tier the paywall screenshot shows. Set it in Pricing, then check the other countries |
| Availability | All countries and regions (it shows "No" now) |
| Family Sharing | On (already) |
| Tax category | App Store software (the default) |

## Localization (English, U.S.)

| Field | Value | Limit |
| --- | --- | --- |
| Display Name | `TubeRemote Pro` | 30 characters |
| Description | `Unlock all Pro features. Pay once.` | 45 characters |

## Review information

- **Screenshot:** `AppStore/screenshots/iphone-6.9/paywall.png`, the paywall the app shows. Apple needs it before the purchase can be reviewed.
- **Review notes:**

  > TubeRemote Pro is a one-time, non-consumable purchase. To reach it: open Settings (gear icon) and tap "Unlock TubeRemote Pro", or tap any feature marked "Pro" such as the Sleep timer in Now Playing. "Restore Purchases" is on the same screen. Pro unlocks the preferred video quality, Skip Ad from the remote, a sleep timer, adding a whole playlist to the queue, sharing a video to the viewer from other apps, several remotes on one viewer, and keeping the queue on the remote. Playing videos from one remote on one viewer stays free.

## Optional: promotional image

`AppStore/in-app-purchase/promotional-image-1024.png` (1024 x 1024, no transparency, no rounded corners). Only needed if you want the purchase to appear on the App Store product page.

## Then

1. On the app version page (1.0, Prepare for Submission), scroll to **In-App Purchases** and add TubeRemote Pro. A first purchase must go in with a version.
2. Agreements, Tax, and Banking: the Paid Apps agreement must be active, or the price and the product won't load in the app.
3. Test with a Sandbox Apple Account on TestFlight (Settings > Developer > Sandbox Apple Account). The purchase is free there.
