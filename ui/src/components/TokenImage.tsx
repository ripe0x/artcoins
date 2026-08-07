/**
 * Token image with a gradient-monogram fallback, previously copy-pasted
 * across TokenCard, TokenDetailPage, and TokenMetadataModal: an <img> that
 * hides itself on load failure (revealing nothing — it does NOT dynamically
 * swap to the monogram, matching the original `onError` behavior at all
 * three call sites), plus a monogram fallback rendered whenever `src` is
 * falsy up front.
 *
 * Sizing/rounding/etc. are fully caller-controlled via the class props so
 * each call site's existing look is preserved exactly.
 */
interface TokenImageProps {
  src: string | null | undefined;
  /** `alt` text for the <img>. */
  alt: string;
  /** Text the monogram fallback is derived from (sliced to 4 chars). */
  symbol: string;
  imgClassName: string;
  fallbackClassName: string;
  monogramClassName: string;
}

export default function TokenImage({
  src,
  alt,
  symbol,
  imgClassName,
  fallbackClassName,
  monogramClassName,
}: TokenImageProps) {
  if (!src) {
    return (
      <div className={fallbackClassName}>
        <span className={monogramClassName}>{symbol.slice(0, 4)}</span>
      </div>
    );
  }

  return (
    <img
      src={src}
      alt={alt}
      className={imgClassName}
      onError={e => {
        (e.currentTarget as HTMLImageElement).style.display = 'none';
      }}
    />
  );
}
