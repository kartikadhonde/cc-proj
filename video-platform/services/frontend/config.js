// Local development default. CI overwrites this file on deploy with
//   window.API_BASE_URL = "/api";
// so the deployed page calls the API through CloudFront (same HTTPS origin).
window.API_BASE_URL = window.API_BASE_URL || "http://localhost:8000";
