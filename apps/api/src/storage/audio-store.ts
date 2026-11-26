export interface AudioStore {
  /** Starts a GCS resumable session; the returned URL accepts PUTs with no credentials. */
  createUpload(object: string, contentType: 'audio/mp4'): Promise<{ uploadUrl: string; expiresAt: Date }>;
  /** Size in bytes, or null when the object doesn't exist (yet). */
  stat(object: string): Promise<{ size: number } | null>;
  readUrl(object: string, ttlSeconds: number): Promise<{ url: string; expiresAt: Date }>;
  deletePrefix(prefix: string): Promise<void>;
}

export const segmentObject = (owner: string, noteId: string, index: number) =>
  `notes/${owner}/${noteId}/${index}.m4a`;

export const notePrefix = (owner: string, noteId: string) => `notes/${owner}/${noteId}/`;

const UPLOAD_TTL_MS = 7 * 24 * 3600 * 1000;

/** In-memory store for tests and credential-less dev; `put` stands in for the phone's upload. */
export class MemoryAudioStore implements AudioStore {
  private readonly objects = new Map<string, number>();

  put(object: string, size: number): void {
    this.objects.set(object, size);
  }

  async createUpload(object: string) {
    return {
      uploadUrl: `https://memory.invalid/upload/${encodeURI(object)}`,
      expiresAt: new Date(Date.now() + UPLOAD_TTL_MS),
    };
  }

  async stat(object: string) {
    const size = this.objects.get(object);
    return size === undefined ? null : { size };
  }

  async readUrl(object: string, ttlSeconds: number) {
    return {
      url: `https://memory.invalid/read/${encodeURI(object)}`,
      expiresAt: new Date(Date.now() + ttlSeconds * 1000),
    };
  }

  async deletePrefix(prefix: string) {
    for (const key of [...this.objects.keys()]) if (key.startsWith(prefix)) this.objects.delete(key);
  }
}
