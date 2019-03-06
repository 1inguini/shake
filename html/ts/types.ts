// Stuff that Shake generates and injects in

// The version of Shake
declare const version: string;
declare const generated: string;

/////////////////////////////////////////////////////////////////////
// PROFILE DATA

type timestamp = int;

interface Trace {
    command: string;
    start: seconds;
    stop: seconds;
}

type pindex = int; // an index into the list of profiles

interface Profile {
    index: pindex; // My index in the list of profiles
    name: string; // Name of the thing I built
    execution: seconds; // Seconds I took to execute
    built: timestamp; // Timestamp at which I was built
    changed: timestamp; // Timestamp at which I last changed
    depends: pindex[]; // What I depend on (always lower than my index)
    rdepends: pindex[]; // What depends on me
    traces: Trace[]; // List of traces
}

type TraceRaw =
    [ string
    , seconds
    , seconds
    ];

type ProfileRaw =
    [ string
    , seconds
    , timestamp
    , timestamp
    , int[] // Optional
    , TraceRaw[] // Optional
    ];

/////////////////////////////////////////////////////////////////////
// PROGRESS DATA

declare const progress: Array<{name: string, values: Progress[]}>;

interface Progress {
    idealSecs: number;
    idealPerc: number;
    actualSecs: number;
    actualPerc: number;
}

/////////////////////////////////////////////////////////////////////
// BASIC UI TOOLKIT

class Prop<A> {
    private val: A;
    private callback: ((val: A) => void);
    constructor(val: A) { this.val = val; }
    public get(): A { return this.val; }
    public set(val: A): void {
        this.val = val;
        this.callback(val);
    }
    public event(next: (val: A) => void): void {
        const old = this.callback;
        this.callback = val => { old(val); next(val); };
    }
}
