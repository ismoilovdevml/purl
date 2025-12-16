// Service type detection and icons for Service Map

// SVG Icons as data URLs for Cytoscape background-image
export const icons = {
  // Languages/Frameworks
  js: `data:image/svg+xml,${encodeURIComponent(`<svg viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg"><rect fill="#F7DF1E" width="32" height="32" rx="4"/><text x="6" y="24" font-family="Arial,sans-serif" font-size="18" font-weight="bold" fill="#000">JS</text></svg>`)}`,

  nodejs: `data:image/svg+xml,${encodeURIComponent(`<svg viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg"><rect fill="#339933" width="32" height="32" rx="4"/><text x="3" y="23" font-family="Arial,sans-serif" font-size="14" font-weight="bold" fill="#fff">Node</text></svg>`)}`,

  go: `data:image/svg+xml,${encodeURIComponent(`<svg viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg"><rect fill="#00ADD8" width="32" height="32" rx="4"/><text x="5" y="22" font-family="Arial,sans-serif" font-size="16" font-weight="bold" fill="#fff">Go</text></svg>`)}`,

  python: `data:image/svg+xml,${encodeURIComponent(`<svg viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg"><rect fill="#3776AB" width="32" height="32" rx="4"/><text x="5" y="22" font-family="Arial,sans-serif" font-size="14" font-weight="bold" fill="#FFD43B">Py</text></svg>`)}`,

  java: `data:image/svg+xml,${encodeURIComponent(`<svg viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg"><rect fill="#007396" width="32" height="32" rx="4"/><text x="3" y="22" font-family="Arial,sans-serif" font-size="12" font-weight="bold" fill="#fff">Java</text></svg>`)}`,

  dotnet: `data:image/svg+xml,${encodeURIComponent(`<svg viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg"><rect fill="#512BD4" width="32" height="32" rx="4"/><text x="2" y="22" font-family="Arial,sans-serif" font-size="11" font-weight="bold" fill="#fff">.NET</text></svg>`)}`,

  rust: `data:image/svg+xml,${encodeURIComponent(`<svg viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg"><rect fill="#DEA584" width="32" height="32" rx="4"/><text x="3" y="22" font-family="Arial,sans-serif" font-size="12" font-weight="bold" fill="#000">Rust</text></svg>`)}`,

  php: `data:image/svg+xml,${encodeURIComponent(`<svg viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg"><rect fill="#777BB4" width="32" height="32" rx="4"/><text x="3" y="22" font-family="Arial,sans-serif" font-size="13" font-weight="bold" fill="#fff">PHP</text></svg>`)}`,

  ruby: `data:image/svg+xml,${encodeURIComponent(`<svg viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg"><rect fill="#CC342D" width="32" height="32" rx="4"/><text x="2" y="22" font-family="Arial,sans-serif" font-size="12" font-weight="bold" fill="#fff">Ruby</text></svg>`)}`,

  // Infrastructure
  database: `data:image/svg+xml,${encodeURIComponent(`<svg viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg"><rect fill="#336791" width="32" height="32" rx="4"/><ellipse cx="16" cy="8" rx="10" ry="4" fill="#fff" opacity="0.9"/><path d="M6 8v16c0 2.2 4.5 4 10 4s10-1.8 10-4V8" fill="none" stroke="#fff" stroke-width="2"/><ellipse cx="16" cy="16" rx="10" ry="4" fill="none" stroke="#fff" stroke-width="2"/></svg>`)}`,

  redis: `data:image/svg+xml,${encodeURIComponent(`<svg viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg"><rect fill="#DC382D" width="32" height="32" rx="4"/><text x="2" y="22" font-family="Arial,sans-serif" font-size="11" font-weight="bold" fill="#fff">Redis</text></svg>`)}`,

  kafka: `data:image/svg+xml,${encodeURIComponent(`<svg viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg"><rect fill="#231F20" width="32" height="32" rx="4"/><text x="1" y="22" font-family="Arial,sans-serif" font-size="10" font-weight="bold" fill="#fff">Kafka</text></svg>`)}`,

  elasticsearch: `data:image/svg+xml,${encodeURIComponent(`<svg viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg"><rect fill="#005571" width="32" height="32" rx="4"/><text x="6" y="22" font-family="Arial,sans-serif" font-size="13" font-weight="bold" fill="#FEC514">ES</text></svg>`)}`,

  mongodb: `data:image/svg+xml,${encodeURIComponent(`<svg viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg"><rect fill="#47A248" width="32" height="32" rx="4"/><text x="1" y="22" font-family="Arial,sans-serif" font-size="9" font-weight="bold" fill="#fff">Mongo</text></svg>`)}`,

  mysql: `data:image/svg+xml,${encodeURIComponent(`<svg viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg"><rect fill="#4479A1" width="32" height="32" rx="4"/><text x="1" y="22" font-family="Arial,sans-serif" font-size="10" font-weight="bold" fill="#fff">MySQL</text></svg>`)}`,

  // Web/Services
  web: `data:image/svg+xml,${encodeURIComponent(`<svg viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg"><rect fill="#4A90D9" width="32" height="32" rx="4"/><circle cx="16" cy="16" r="9" fill="none" stroke="#fff" stroke-width="2"/><ellipse cx="16" cy="16" rx="4" ry="9" fill="none" stroke="#fff" stroke-width="2"/><line x1="7" y1="16" x2="25" y2="16" stroke="#fff" stroke-width="2"/></svg>`)}`,

  api: `data:image/svg+xml,${encodeURIComponent(`<svg viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg"><rect fill="#FF6B35" width="32" height="32" rx="4"/><text x="4" y="22" font-family="Arial,sans-serif" font-size="13" font-weight="bold" fill="#fff">API</text></svg>`)}`,

  gateway: `data:image/svg+xml,${encodeURIComponent(`<svg viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg"><rect fill="#6C5CE7" width="32" height="32" rx="4"/><path d="M8 10h16M8 16h16M8 22h16" stroke="#fff" stroke-width="2" stroke-linecap="round"/><circle cx="22" cy="10" r="2" fill="#fff"/><circle cx="10" cy="16" r="2" fill="#fff"/><circle cx="22" cy="22" r="2" fill="#fff"/></svg>`)}`,

  // Cloud/External
  cloud: `data:image/svg+xml,${encodeURIComponent(`<svg viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg"><rect fill="#0078D4" width="32" height="32" rx="4"/><path d="M8 22c-2.2 0-4-1.8-4-4s1.8-4 4-4c.3-2.8 2.7-5 5.5-5 2.5 0 4.6 1.7 5.3 4 .2 0 .5-.1.7-.1 2.5 0 4.5 2 4.5 4.5s-2 4.5-4.5 4.5H8z" fill="#fff"/></svg>`)}`,

  external: `data:image/svg+xml,${encodeURIComponent(`<svg viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg"><rect fill="#6B7280" width="32" height="32" rx="4"/><path d="M12 8h12v12M24 8L10 22" stroke="#fff" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"/></svg>`)}`,

  // Default
  service: `data:image/svg+xml,${encodeURIComponent(`<svg viewBox="0 0 32 32" xmlns="http://www.w3.org/2000/svg"><rect fill="#10B981" width="32" height="32" rx="4"/><circle cx="16" cy="16" r="8" fill="none" stroke="#fff" stroke-width="2"/><circle cx="16" cy="16" r="3" fill="#fff"/></svg>`)}`,
};

// Service type patterns for auto-detection
const SERVICE_PATTERNS = [
  // Languages/Frameworks - specific first
  { pattern: /node|express|nestjs|npm/i, type: 'nodejs', label: 'Node.js' },
  { pattern: /react|vue|angular|svelte|frontend|web-app|ui/i, type: 'js', label: 'JavaScript' },
  { pattern: /dotnet|aspnet|csharp|\.net/i, type: 'dotnet', label: '.NET' },
  { pattern: /go|golang/i, type: 'go', label: 'Go' },
  { pattern: /python|django|flask|fastapi|py/i, type: 'python', label: 'Python' },
  { pattern: /java|spring|kotlin|jvm/i, type: 'java', label: 'Java' },
  { pattern: /rust|cargo/i, type: 'rust', label: 'Rust' },
  { pattern: /php|laravel|symfony/i, type: 'php', label: 'PHP' },
  { pattern: /ruby|rails|sinatra/i, type: 'ruby', label: 'Ruby' },

  // Databases
  { pattern: /postgres|postgresql|pgsql/i, type: 'database', label: 'PostgreSQL' },
  { pattern: /mysql|mariadb/i, type: 'mysql', label: 'MySQL' },
  { pattern: /mongo|mongodb/i, type: 'mongodb', label: 'MongoDB' },
  { pattern: /redis|cache/i, type: 'redis', label: 'Redis' },
  { pattern: /elastic|elasticsearch|opensearch/i, type: 'elasticsearch', label: 'Elasticsearch' },
  { pattern: /sql|database|db$/i, type: 'database', label: 'Database' },

  // Message Queues
  { pattern: /kafka/i, type: 'kafka', label: 'Kafka' },
  { pattern: /rabbit|rabbitmq|amqp|queue|mq/i, type: 'kafka', label: 'Queue' },

  // API/Gateway
  { pattern: /gateway|ingress|proxy|nginx|envoy/i, type: 'gateway', label: 'Gateway' },
  { pattern: /api|rest|graphql/i, type: 'api', label: 'API' },

  // Cloud/External
  { pattern: /cdn|cloudflare|akamai|fastly/i, type: 'cloud', label: 'CDN' },
  { pattern: /aws|gcp|azure|cloud/i, type: 'cloud', label: 'Cloud' },
  { pattern: /external|third-party|vendor/i, type: 'external', label: 'External' },

  // Web
  { pattern: /web|http|frontend/i, type: 'web', label: 'Web' },
];

// Detect service type from name
export function detectServiceType(serviceName) {
  if (!serviceName) return { type: 'service', label: 'Service', icon: icons.service };

  const name = serviceName.toLowerCase();

  for (const { pattern, type, label } of SERVICE_PATTERNS) {
    if (pattern.test(name)) {
      return {
        type,
        label,
        icon: icons[type] || icons.service,
      };
    }
  }

  return { type: 'service', label: 'Service', icon: icons.service };
}

// Get icon URL for a service type
export function getIconUrl(type) {
  return icons[type] || icons.service;
}

// Get all available service types (for filters)
export const serviceTypes = [
  { type: 'web', label: 'Web', icon: icons.web },
  { type: 'api', label: 'API', icon: icons.api },
  { type: 'gateway', label: 'Gateway', icon: icons.gateway },
  { type: 'nodejs', label: 'Node.js', icon: icons.nodejs },
  { type: 'go', label: 'Go', icon: icons.go },
  { type: 'python', label: 'Python', icon: icons.python },
  { type: 'java', label: 'Java', icon: icons.java },
  { type: 'dotnet', label: '.NET', icon: icons.dotnet },
  { type: 'database', label: 'Database', icon: icons.database },
  { type: 'redis', label: 'Redis', icon: icons.redis },
  { type: 'kafka', label: 'Kafka', icon: icons.kafka },
  { type: 'elasticsearch', label: 'Elasticsearch', icon: icons.elasticsearch },
  { type: 'cloud', label: 'Cloud', icon: icons.cloud },
  { type: 'external', label: 'External', icon: icons.external },
];

// Health status colors
export const healthColors = {
  healthy: '#10b981',
  degraded: '#f59e0b',
  critical: '#ef4444',
  unknown: '#6b7280',
};

// Get health color
export function getHealthColor(status) {
  return healthColors[status] || healthColors.unknown;
}
