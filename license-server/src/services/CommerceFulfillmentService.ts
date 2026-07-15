import type { AppConfig } from "../config.js";

export class CommerceFulfillmentError extends Error {
  constructor(
    public readonly code: string,
    message: string,
    public readonly retryable: boolean,
  ) {
    super(message);
  }
}

export interface CommerceLicenseOperations {
  provisionLifetimeLicense(input: {
    email: string;
    orderProvider: string;
    orderId: string;
    plan: "pro_lifetime";
    seats: number;
    majorVersion: number;
    purchasedAt: Date;
    updatesDays: number;
  }): Promise<unknown>;
  applyCommerceRefund(input: {
    orderProvider: string;
    orderId: string;
    fullRefund: boolean;
    refundedAt: Date;
    refundedAmount: number;
    orderTotal: number;
  }): Promise<unknown>;
}

interface LemonSqueezyPayload {
  data?: {
    id?: string | number;
    attributes?: {
      user_email?: string;
      created_at?: string;
      refunded_at?: string | null;
      total?: number;
      refunded_amount?: number;
      first_order_item?: { variant_id?: string | number };
    };
  };
}

export class CommerceFulfillmentService {
  constructor(
    private readonly config: AppConfig,
    private readonly licenses: CommerceLicenseOperations,
  ) {}

  async process(input: {
    provider: string;
    eventName: string;
    payload: unknown;
  }): Promise<{ action: "provisioned" | "refunded" | "ignored" }> {
    if (input.provider !== "lemonsqueezy") {
      throw new CommerceFulfillmentError("UNSUPPORTED_COMMERCE_PROVIDER", "Unsupported commerce provider", false);
    }

    if (input.eventName === "order_created") {
      await this.processOrderCreated(input.payload as LemonSqueezyPayload);
      return { action: "provisioned" };
    }
    if (input.eventName === "order_refunded") {
      await this.processOrderRefunded(input.payload as LemonSqueezyPayload);
      return { action: "refunded" };
    }
    return { action: "ignored" };
  }

  private async processOrderCreated(payload: LemonSqueezyPayload): Promise<void> {
    const orderId = payload.data?.id;
    const attributes = payload.data?.attributes;
    const variantId = attributes?.first_order_item?.variant_id;
    if (orderId == null || !attributes?.user_email || !attributes.created_at || variantId == null) {
      throw new CommerceFulfillmentError("INVALID_ORDER_PAYLOAD", "Order payload is missing required fields", false);
    }
    const mapping = this.config.commercial.productMappings.find(
      (item) => item.provider === "lemonsqueezy" && item.variantId === String(variantId),
    );
    if (!mapping) {
      throw new CommerceFulfillmentError(
        "UNKNOWN_PRODUCT_VARIANT",
        `No product mapping exists for Lemon Squeezy variant ${String(variantId)}`,
        false,
      );
    }
    const purchasedAt = new Date(attributes.created_at);
    if (Number.isNaN(purchasedAt.getTime())) {
      throw new CommerceFulfillmentError("INVALID_ORDER_DATE", "Order payload contains an invalid purchase date", false);
    }

    await this.licenses.provisionLifetimeLicense({
      email: attributes.user_email,
      orderProvider: "lemonsqueezy",
      orderId: String(orderId),
      plan: mapping.plan,
      seats: mapping.seats,
      majorVersion: mapping.majorVersion,
      purchasedAt,
      updatesDays: mapping.updatesDays,
    });
  }

  private async processOrderRefunded(payload: LemonSqueezyPayload): Promise<void> {
    const orderId = payload.data?.id;
    const attributes = payload.data?.attributes;
    if (orderId == null || !attributes) {
      throw new CommerceFulfillmentError("INVALID_REFUND_PAYLOAD", "Refund payload is missing required fields", false);
    }
    const orderTotal = attributes.total;
    const refundedAmount = attributes.refunded_amount;
    if (
      typeof orderTotal !== "number" ||
      typeof refundedAmount !== "number" ||
      !Number.isSafeInteger(orderTotal) ||
      !Number.isSafeInteger(refundedAmount) ||
      orderTotal <= 0 ||
      refundedAmount <= 0 ||
      refundedAmount > orderTotal
    ) {
      throw new CommerceFulfillmentError(
        "INVALID_REFUND_AMOUNT",
        "Refund amounts must be positive integer minor units and cannot exceed the order total",
        false,
      );
    }
    const refundedAt = attributes.refunded_at ? new Date(attributes.refunded_at) : new Date();

    await this.licenses.applyCommerceRefund({
      orderProvider: "lemonsqueezy",
      orderId: String(orderId),
      fullRefund: refundedAmount === orderTotal,
      refundedAt: Number.isNaN(refundedAt.getTime()) ? new Date() : refundedAt,
      refundedAmount,
      orderTotal,
    });
  }
}
