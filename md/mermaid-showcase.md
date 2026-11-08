# Mermaid Diagram Showcase

How the Halcyon *Aurora* synthesizer is built, sold and shipped, told in twelve kinds
of Mermaid diagram: flowcharts, a sequence, classes, states, entities, a user journey,
a timeline, a Gantt chart, a pie, a git graph, a mind map and a quadrant chart.

## Flowchart (top-down): a voice is allocated

```mermaid
graph TD
  A[Key pressed] --> B{Free voice?}
  B -->|yes| C[Assign voice]
  B -->|no| D[Steal the oldest voice]
  D --> C
  C --> E[Start envelopes]
  E --> F((Sound))
```

## Flowchart (left-right) with subgraphs: the signal path

```mermaid
flowchart LR
  subgraph Oscillators
    O1[Wavetable A] --> MIX
    O2[Wavetable B] --> MIX
    SUB[Sub oscillator] --> MIX
  end
  subgraph Voice
    MIX[Mixer] --> F[Ladder filter] --> V[VCA]
  end
  subgraph Master
    V --> FX[Chorus · Delay · Reverb] --> OUT[(Stereo out)]
  end
  LFO[LFO 1] -.->|cutoff| F
  ENV[Envelope 2] -.->|amount| V
```

## Sequence diagram: a patch is shared

```mermaid
sequenceDiagram
  participant P as Player
  participant A as Aurora
  participant C as Halcyon Cloud
  participant F as Friend
  P->>A: Hold SHARE for two seconds
  A->>A: Sign the patch
  A->>C: Upload signed patch
  C-->>A: Share code H7-QX2
  P->>F: "Try H7-QX2"
  F->>C: Fetch H7-QX2
  C-->>F: Patch + signature
  Note over C,F: The signature is checked again on download
```

## Class diagram: the patch model

```mermaid
classDiagram
  class Patch {
    +String name
    +Category category
    +sign(key) Signature
  }
  class Oscillator {
    +Waveform shape
    +float detune
  }
  class Filter {
    +float cutoff
    +float resonance
  }
  class Envelope {
    +float attack
    +float decay
    +float sustain
    +float release
  }
  Patch "1" *-- "3" Oscillator
  Patch "1" *-- "1" Filter
  Patch "1" *-- "4" Envelope
```

## State diagram: an envelope stage

```mermaid
stateDiagram-v2
  [*] --> Idle
  Idle --> Attack: note on
  Attack --> Decay: peak reached
  Decay --> Sustain: level reached
  Sustain --> Release: note off
  Attack --> Release: note off
  Decay --> Release: note off
  Release --> Idle: silent
```

## Entity-relationship diagram: the patch library

```mermaid
erDiagram
  OWNER ||--o{ INSTRUMENT : registers
  INSTRUMENT ||--o{ BANK : stores
  BANK ||--|{ PATCH : contains
  PATCH }o--o{ TAG : "is tagged"
  OWNER ||--o{ SHARE : creates
  SHARE }o--|| PATCH : points-to
```

## User journey: first evening with an Aurora

```mermaid
journey
  title First evening with an Aurora
  section Unbox
    Lift it out: 5: Player
    Find the power supply: 3: Player
  section Play
    First chord: 5: Player
    Browse factory patches: 4: Player
  section Make
    Save a first patch: 4: Player
    Share it with a friend: 5: Player, Friend
```

## Timeline: the Aurora family

```mermaid
timeline
  title The Aurora family
  2021 : Aurora prototype : Eight voices
  2023 : Aurora 1.0 : Wavetables
  2024 : Nocturne : Desktop module
  2025 : Aurora 2 : Sixteen voices : MPE
  2026 : Halcyon Cloud : Signed patch sharing
```

## Gantt chart: Aurora 2.3 firmware

```mermaid
gantt
  title Aurora 2.3 firmware
  dateFormat YYYY-MM-DD
  section Engine
    Filter rewrite     :a1, 2026-09-01, 21d
    Voice stealing     :a2, after a1, 10d
  section Cloud
    Signed export      :b1, 2026-09-10, 20d
    Share codes        :b2, after b1, 12d
  section Release
    Beta               :c1, after a2, 14d
    Public release     :milestone, after c1, 0d
```

## Pie chart: patches shared, by category

```mermaid
pie title Patches shared, by category
  "Pads" : 38
  "Bass" : 24
  "Leads" : 19
  "Keys" : 11
  "Effects" : 8
```

## Git graph: the firmware branches

```mermaid
gitGraph
  commit id: "2.2.0"
  branch filter-rewrite
  checkout filter-rewrite
  commit id: "ladder model"
  commit id: "drive stage"
  checkout main
  commit id: "2.2.1 fix"
  merge filter-rewrite
  commit id: "2.3.0-beta"
```

## Mind map: what makes a sound

```mermaid
mindmap
  root((Aurora voice))
    Oscillators
      Wavetable
      Sub
      Noise
    Filter
      Ladder
      State variable
    Modulation
      LFOs
      Envelopes
      Mod wheel
    Effects
      Chorus
      Delay
      Reverb
```

## Quadrant chart: factory patches

```mermaid
quadrantChart
  title Factory patches: brightness and movement
  x-axis Dark --> Bright
  y-axis Static --> Evolving
  quadrant-1 Shimmer
  quadrant-2 Drift
  quadrant-3 Foundation
  quadrant-4 Cut
  Glass Choir: [0.8, 0.85]
  Night Bus: [0.2, 0.75]
  Iron Bass: [0.25, 0.2]
  Snap Lead: [0.85, 0.3]
```
