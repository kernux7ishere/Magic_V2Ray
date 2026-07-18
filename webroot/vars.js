const MODDIR = "/data/adb/modules/magic_v2ray";
const DATADIR = "/data/adb/magic_v2ray";
const PROFILES_FILE = `${DATADIR}/profiles.base64`;
const SETTINGS_FILE = `${DATADIR}/settings.base64`;
const ACTIVE_FILE = `${DATADIR}/active_config.txt`;
const CONFIG_JSON = `${DATADIR}/config.json`;
const STUB_DIR = "/dev/sysctl_stubs";
const TIME_RES_FILE = `${STUB_DIR}/run/time_res`;
 
let profiles = {};
let activeConfig = null;
let advSettings = {
    loglevel: "none",
    sniffing: true,
    routeOnly: false,
    preferIpv6: false,
    mux: false,
    mux_connections: 8,
    fragment: false,
    fragment_packets: "tlshello",
    fragment_length: "50-100",
    fragment_interval: "10-20",
    mtu: 1350,
    pinnedPeerCertSha256: "",
    dnsViaProxy: true,
    localDns: false,
    fakeDnsLocal: false,
    vpnDns: "1.1.1.1",
    foreignDns: "1.1.1.1",
    domesticDns: "223.5.5.5",
    routingRules: []
};
let currentLang = 'en';
let currentEditingCategory = null;
let currentEditingNodeId = null;
let currentEditingProtocol = null;
let categoryExpandedState = {};

// Routing Settings tab
let currentEditingRuleIndex = null;

// Logging
let _logAutoRefreshTimer = null;
let _logTailEnabled = true;
let _logCurrentFilter = 'all';
let _logLastLineCount = 0;
let _logAllLines = [];

// Network latency monitor
const LATENCY_MAX_SAMPLES = 60;
let _latencyPollTimer = null;
let _latencySamples = [];