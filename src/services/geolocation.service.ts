import {
  IP_API_BATCH_URL,
  IP_API_RATE_LIMIT_DELAY,
  IP_API_MAX_BATCH_SIZE,
} from '../config/constants';

export interface GeolocationData {
  status: 'success' | 'fail';
  country?: string;
  region?: string;
  city?: string;
  lat?: number;
  lon?: number;
  isp?: string;
  query?: string;
  message?: string;
}

export interface FormattedLocation {
  full: string;
  country: string;
  region?: string;
  city?: string;
  countryCode?: string;
}

export class GeolocationService {
  private lastRequestTime = 0;

  /**
   * Get geolocation for a single IP address
   */
  async getGeolocation(ip: string): Promise<GeolocationData | null> {
    await this.rateLimitDelay();

    try {
      const response = await fetch(`http://ip-api.com/json/${ip}`);
      const data = (await response.json()) as GeolocationData;

      return data;
    } catch (error) {
      console.error(`Failed to fetch geolocation for IP ${ip}:`, error);
      return null;
    }
  }

  /**
   * Get geolocation for multiple IP addresses (batch)
   */
  async getBatchGeolocation(ips: string[]): Promise<(GeolocationData | null)[]> {
    if (ips.length === 0) {
      return [];
    }

    await this.rateLimitDelay();

    // Split into batches if needed
    const results: (GeolocationData | null)[] = [];

    for (let i = 0; i < ips.length; i += IP_API_MAX_BATCH_SIZE) {
      const batch = ips.slice(i, i + IP_API_MAX_BATCH_SIZE);
      const batchResults = await this.fetchBatch(batch);
      results.push(...batchResults);

      // Add delay between batches if we have more
      if (i + IP_API_MAX_BATCH_SIZE < ips.length) {
        await this.delay(IP_API_RATE_LIMIT_DELAY);
      }
    }

    return results;
  }

  /**
   * Fetch a single batch from ip-api.com
   */
  private async fetchBatch(ips: string[]): Promise<(GeolocationData | null)[]> {
    if (ips.length === 0) {
      return [];
    }

    try {
      const requestBody = ips.map((ip) => ({ query: ip }));
      const response = await fetch(IP_API_BATCH_URL, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(requestBody),
      });

      if (!response.ok) {
        throw new Error(`ip-api.com returned ${response.status}`);
      }

      const data = (await response.json()) as GeolocationData[];
      return data;
    } catch (error) {
      console.error('Failed to fetch batch geolocation:', error);
      return ips.map(() => null);
    }
  }

  /**
   * Rate limit delay
   */
  private async rateLimitDelay(): Promise<void> {
    const now = Date.now();
    const timeSinceLastRequest = now - this.lastRequestTime;

    if (timeSinceLastRequest < IP_API_RATE_LIMIT_DELAY) {
      await this.delay(IP_API_RATE_LIMIT_DELAY - timeSinceLastRequest);
    }

    this.lastRequestTime = Date.now();
  }

  /**
   * Delay helper
   */
  private delay(ms: number): Promise<void> {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  /**
   * Format geolocation data into a readable string
   */
  formatLocation(data: GeolocationData | null): FormattedLocation {
    if (!data || data.status !== 'success') {
      return {
        full: 'Unknown Location',
        country: 'Unknown',
      };
    }

    const parts: string[] = [];

    if (data.city) {
      parts.push(data.city);
    }

    if (data.region) {
      parts.push(data.region);
    }

    if (data.country) {
      parts.push(data.country);
    }

    return {
      full: parts.join(', ') || 'Unknown Location',
      country: data.country || 'Unknown',
      region: data.region,
      city: data.city,
      countryCode: this.extractCountryCode(data.country),
    };
  }

  /**
   * Extract country code from country name (basic implementation)
   */
  private extractCountryCode(country?: string): string | undefined {
    if (!country) {
      return undefined;
    }

    // Common countries mapping
    const countryMap: Record<string, string> = {
      'United States': 'US',
      'United Kingdom': 'GB',
      Australia: 'AU',
      Canada: 'CA',
      Germany: 'DE',
      France: 'FR',
      Japan: 'JP',
      Singapore: 'SG',
      India: 'IN',
      Indonesia: 'ID',
      Netherlands: 'NL',
      Brazil: 'BR',
    };

    return countryMap[country];
  }

  /**
   * Parse IP from auth log line
   */
  parseIPFromLog(logLine: string): string | null {
    // Match IP address patterns
    const ipMatch = logLine.match(/(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/);
    return ipMatch ? (ipMatch[1] ?? null) : null;
  }

  /**
   * Check if IP is private/local
   */
  isPrivateIP(ip: string): boolean {
    const privateRanges = [
      /^10\./,
      /^172\.(1[6-9]|2[0-9]|3[0-1])\./,
      /^192\.168\./,
      /^127\./,
      /^localhost$/i,
      /^::1$/,
      /^fe80:/,
    ];

    return privateRanges.some((range) => range.test(ip));
  }

  /**
   * Get cached geolocation from access logs
   */
  getCachedLocation(_ip: string): GeolocationData | null {
    // This would be implemented by querying the database
    // for existing geolocation data for this IP
    return null;
  }
}

// Lazy singleton instance
let _geolocationServiceInstance: GeolocationService | null = null;
/**
 * Get the singleton GeolocationService instance.
 *
 * Creates and caches the GeolocationService on first invocation; subsequent calls return the same instance.
 *
 * @returns The singleton GeolocationService instance.
 */
export function getGeolocationService(): GeolocationService {
  if (!_geolocationServiceInstance) {
    _geolocationServiceInstance = new GeolocationService();
  }
  return _geolocationServiceInstance;
}

// Convenience export for backward compatibility
export const geolocationService = new Proxy({} as GeolocationService, {
  get(target, prop) {
    return getGeolocationService()[prop as keyof GeolocationService];
  },
});