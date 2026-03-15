/** Resize + JPEG so data URL stays under ~1.1M chars for Claude vision + Vercel. */
const MAX_DATA_URL_CHARS = 1_100_000;

export function fileToVisionSafeDataUrl(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    if (!file.type.startsWith("image/")) {
      reject(new Error("Not an image"));
      return;
    }
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => {
      URL.revokeObjectURL(url);
      let w = img.naturalWidth;
      let h = img.naturalHeight;
      const maxW = 1400;
      if (w > maxW) {
        h = (h * maxW) / w;
        w = maxW;
      }
      const canvas = document.createElement("canvas");
      canvas.width = Math.round(w);
      canvas.height = Math.round(h);
      const ctx = canvas.getContext("2d");
      if (!ctx) {
        reject(new Error("Canvas unsupported"));
        return;
      }
      ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
      let q = 0.85;
      let dataUrl = canvas.toDataURL("image/jpeg", q);
      let scale = 1;
      while (dataUrl.length > MAX_DATA_URL_CHARS && (q > 0.5 || scale > 0.4)) {
        if (q > 0.5) q -= 0.07;
        else {
          scale *= 0.85;
          canvas.width = Math.max(320, Math.round(w * scale));
          canvas.height = Math.max(240, Math.round(h * scale));
          ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
          q = 0.8;
        }
        dataUrl = canvas.toDataURL("image/jpeg", q);
      }
      resolve(dataUrl);
    };
    img.onerror = () => {
      URL.revokeObjectURL(url);
      reject(new Error("Image load failed"));
    };
    img.src = url;
  });
}
