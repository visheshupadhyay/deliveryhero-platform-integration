import http from 'k6/http';
import { check } from 'k6';

export const options = {
  scenarios: {
    million_requests: {
      executor: 'shared-iterations',
      vus: 60,
      iterations: 1000000,
      maxDuration: '30m',
    },
  },
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<250', 'p(99)<500'],
  },
};

const baseUrl = __ENV.BASE_URL || 'http://host.docker.internal:8081';
const outletId = __ENV.OUTLET_ID || '1';

export default function () {
  const response = http.get(`${baseUrl}/api/v1/outlets/${outletId}/menu`);
  check(response, {
    'status is 200': (res) => res.status === 200,
    'response contains effectiveMenu': (res) => (res.body || '').includes('effectiveMenu'),
  });
}
