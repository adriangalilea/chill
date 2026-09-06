import os

/// The app's trace, every decision and every exchange, numbers and
/// reasons `.public` (nothing personal exists here). Read it live with
///   log stream --predicate 'subsystem == "garden.untitled.chill"'
/// beside the daemon's `garden.untitled.chilld`: a click that went
/// nowhere is either missing here or answered here.
let log = Logger(subsystem: "garden.untitled.chill", category: "app")
