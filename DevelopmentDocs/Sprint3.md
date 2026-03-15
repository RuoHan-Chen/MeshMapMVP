### MeshMap MVP – Iteration 3

#### Map events and labels
- **Timestamps on map labels**: Each event pin shows a relative time (e.g. “5m ago”), and the label detail sheet shows full date/time.
- **5 km placement + visibility limit**:
  - Users can only place new events within **5 km** of their current location.
  - Events more than **5 km** away from the user are hidden from the map.
- **Event expiration**:
  - Events expire and are hidden after **1 hour**.
- **Configurable event types**:
  - Three primary types: **Hazard**, **Help**, **Other**, backed by `EventTypesConfig`.
  - Each type has a configurable name and description.
- **Custom event names and descriptions**:
  - When placing an event, users can optionally set a **label name** and **description** for that specific event.
- **Icon picker for events**:
  - When creating an event, users can choose from a set of **SF Symbols**.
  - The chosen icon is stored with the event and shown on the map and in the detail sheet.
- **Vote-based color gradient**:
  - Event pins are colored from **green → yellow → red** based on validity confidence (up/down votes).
  - Higher confidence (more valid votes) appears **redder**.
- **Event deletion (local)**:
  - From the label detail sheet, any event can be **deleted on the local device**.
  - From Dashboard (see below), users can clear **all** local map events.

#### Map UX and clustering
- **Recenter button**:
  - A `location.circle.fill` button recenters the map on the user’s current location, or fits all annotations if location is unavailable.
- **Event clustering**:
  - Events that are placed within ~**60 meters** of each other are grouped into a **cluster** and share a single pin.
  - Cluster pin shows:
    - Icon and name from the **highest-confidence** event.
    - A summary like `“3 events · top 80%”`.
  - Tapping a cluster:
    - If there is **one** event: opens that event’s detail sheet.
    - If there are **multiple** events: opens a **cluster list sheet**.
- **Cluster list sheet**:
  - Shows all events in the cluster **ranked by confidence score** (validity).
  - Each row shows icon, name, optional description, relative time, and score percentage.
  - Selecting a row opens the standard event detail sheet (vote + delete) for that event.

#### Chat messages
- **Message expiration**:
  - Chat messages expire after **20 minutes** and are no longer shown in the chat list.
- **Local-only clearing**:
  - Dashboard now includes an option to **clear all chat messages** on the current device.

#### Dashboard additions
- **Maintenance (local only) section**:
  - **Clear chat messages** – removes all local messages.
  - **Clear map events** – removes all local events and their votes.
  - **Clear log** – clears the mesh debug log.

#### Other implementation notes
- **Stable map annotations**:
  - Event clusters now use stable IDs derived from underlying events, preventing pins from flashing due to annotation identity changes.
- **Map tile cache sharing**:
  - Apple Maps / MapKit tile cache cannot be read or transmitted, and mesh envelopes are limited to 512 bytes.
  - As a result, **offline map tiles cannot realistically be shared over the mesh**; each device must cache tiles locally using the existing “Cache current map area” action.

