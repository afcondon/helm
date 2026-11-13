// A stand-in for `@julusian/midi`, for the hub's conformance replay
// (`conformance/HELM-HUB.md`). The hub loads it when HELM_HUB_FAKE_MIDI is
// set, and then touches no real MIDI port.
//
// Two outputs and one input, the same on every machine:
//   "loop"  an output whose every message comes straight back in on the
//           input of the same name
//   "sink"  an output that goes nowhere

const listeners = new Set(); // handlers of every open "loop" input

class Input {
  getPortCount() {
    return 1;
  }
  getPortName() {
    return "loop";
  }
  ignoreTypes() {}
  on(event, handler) {
    if (event === "message") this.handler = handler;
  }
  openPort() {
    if (this.handler) listeners.add(this.handler);
  }
  closePort() {
    listeners.delete(this.handler);
  }
}

const outputNames = ["loop", "sink"];

class Output {
  getPortCount() {
    return outputNames.length;
  }
  getPortName(index) {
    return outputNames[index];
  }
  openPort(index) {
    this.name = outputNames[index];
  }
  sendMessage(data) {
    if (this.name === "loop") for (const handler of listeners) handler(0, data);
  }
  closePort() {}
}

export default { Input, Output };
