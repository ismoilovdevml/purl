// Service type detection and icons for Service Map

// Service type configurations with colors and abbreviations
export const serviceTypeConfig = {
  // Languages/Frameworks
  js: { color: '#F7DF1E', textColor: '#000', abbrev: 'JS', label: 'JavaScript' },
  nodejs: { color: '#339933', textColor: '#fff', abbrev: 'Node', label: 'Node.js' },
  go: { color: '#00ADD8', textColor: '#fff', abbrev: 'Go', label: 'Go' },
  python: { color: '#3776AB', textColor: '#FFD43B', abbrev: 'Py', label: 'Python' },
  java: { color: '#007396', textColor: '#fff', abbrev: 'Java', label: 'Java' },
  dotnet: { color: '#512BD4', textColor: '#fff', abbrev: '.NET', label: '.NET' },
  rust: { color: '#DEA584', textColor: '#000', abbrev: 'Rs', label: 'Rust' },
  php: { color: '#777BB4', textColor: '#fff', abbrev: 'PHP', label: 'PHP' },
  ruby: { color: '#CC342D', textColor: '#fff', abbrev: 'Rb', label: 'Ruby' },

  // Infrastructure
  database: { color: '#336791', textColor: '#fff', abbrev: 'DB', label: 'Database' },
  redis: { color: '#DC382D', textColor: '#fff', abbrev: 'RDS', label: 'Redis' },
  kafka: { color: '#231F20', textColor: '#fff', abbrev: 'KFK', label: 'Kafka' },
  elasticsearch: { color: '#005571', textColor: '#FEC514', abbrev: 'ES', label: 'Elasticsearch' },
  mongodb: { color: '#47A248', textColor: '#fff', abbrev: 'MDB', label: 'MongoDB' },
  mysql: { color: '#4479A1', textColor: '#fff', abbrev: 'SQL', label: 'MySQL' },

  // Web/Services
  web: { color: '#4A90D9', textColor: '#fff', abbrev: 'WEB', label: 'Web' },
  api: { color: '#FF6B35', textColor: '#fff', abbrev: 'API', label: 'API' },
  gateway: { color: '#6C5CE7', textColor: '#fff', abbrev: 'GW', label: 'Gateway' },

  // Cloud/External
  cloud: { color: '#0078D4', textColor: '#fff', abbrev: 'CLD', label: 'Cloud' },
  external: { color: '#6B7280', textColor: '#fff', abbrev: 'EXT', label: 'External' },

  // Default
  service: { color: '#10B981', textColor: '#fff', abbrev: 'SVC', label: 'Service' },
};

// Generate SVG data URL for a service type
export function generateIconSvg(type) {
  const config = serviceTypeConfig[type] || serviceTypeConfig.service;
  const svg = `<svg viewBox="0 0 48 48" xmlns="http://www.w3.org/2000/svg">
    <rect fill="${config.color}" width="48" height="48" rx="8"/>
    <text x="24" y="30" font-family="system-ui,-apple-system,sans-serif" font-size="14" font-weight="700" fill="${config.textColor}" text-anchor="middle">${config.abbrev}</text>
  </svg>`;
  return `data:image/svg+xml,${encodeURIComponent(svg)}`;
}

// SVG Icons as data URLs for Cytoscape background-image
export const icons = Object.fromEntries(
  Object.keys(serviceTypeConfig).map(type => [type, generateIconSvg(type)])
);

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
  if (!serviceName) return {
    type: 'service',
    label: 'Service',
    icon: icons.service,
    ...serviceTypeConfig.service
  };

  const name = serviceName.toLowerCase();

  for (const { pattern, type, label } of SERVICE_PATTERNS) {
    if (pattern.test(name)) {
      const config = serviceTypeConfig[type] || serviceTypeConfig.service;
      return {
        type,
        label,
        icon: icons[type] || icons.service,
        ...config,
      };
    }
  }

  return {
    type: 'service',
    label: 'Service',
    icon: icons.service,
    ...serviceTypeConfig.service
  };
}

// Get icon URL for a service type
export function getIconUrl(type) {
  return icons[type] || icons.service;
}

// Get config for a service type
export function getServiceConfig(type) {
  return serviceTypeConfig[type] || serviceTypeConfig.service;
}

// Get all available service types (for filters)
export const serviceTypes = Object.entries(serviceTypeConfig)
  .filter(([type]) => type !== 'service')
  .map(([type, config]) => ({
    type,
    label: config.label,
    color: config.color,
    icon: icons[type],
  }));

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
