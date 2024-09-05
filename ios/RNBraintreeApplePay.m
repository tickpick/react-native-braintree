@import PassKit;
#import "RNBraintreeApplePay.h"
#import "BraintreeCore.h"
#import "BTDataCollector.h"
#import "BraintreePaymentFlow.h"
#import "BraintreeApplePay.h"

@interface RNBraintreeApplePay()<PKPaymentAuthorizationViewControllerDelegate>

@property (nonatomic, strong) BTAPIClient *apiClient;
@property (nonatomic, strong) BTDataCollector *dataCollector;
@property (nonatomic, strong) RCTPromiseResolveBlock resolve;
@property (nonatomic, strong) RCTPromiseRejectBlock reject;
@property (nonatomic, assign) BOOL isApplePaymentAuthorized;

@end

@implementation RNBraintreeApplePay

RCT_EXPORT_MODULE()

RCT_EXPORT_BLOCKING_SYNCHRONOUS_METHOD(isApplePayAvailable) {
    BOOL canMakePayments = [PKPaymentAuthorizationViewController canMakePaymentsUsingNetworks:
            @[PKPaymentNetworkVisa, PKPaymentNetworkMasterCard, PKPaymentNetworkAmex, PKPaymentNetworkDiscover]];
    return [NSNumber numberWithBool:canMakePayments];
}

RCT_EXPORT_METHOD(runApplePay: (NSDictionary *)options
                     resolver: (RCTPromiseResolveBlock)resolve
                     rejecter: (RCTPromiseRejectBlock)reject) {
    NSString *companyName = options[@"companyName"];
    NSString *merchantIdentifier = options[@"merchantIdentifier"]; //do we need this?
    NSString *amount = options[@"amount"];
    NSString *clientToken = options[@"clientToken"];
    NSString *currencyCode = options[@"currencyCode"];
    NSString *countryCode = options[@"countryCode"];
    NSArray *paymentSummaryItems = options[@"paymentSummaryItems"];
    NSArray *shippingMethods = options[@"shippingMethods"];

    if (!companyName) {
        reject(@"NO_COMPANY_NAME", @"You must provide a `companyName`", nil);
        return;
    }
    if (!amount) {
        reject(@"NO_TOTAL_PRICE", @"You must provide a `amount`", nil);
        return;
    }

    self.apiClient = [[BTAPIClient alloc] initWithAuthorization: clientToken];
    self.dataCollector = [[BTDataCollector alloc] initWithAPIClient:self.apiClient];

    BTApplePayClient *applePayClient = [[BTApplePayClient alloc] initWithAPIClient: self.apiClient];

    [applePayClient paymentRequest:^(PKPaymentRequest * _Nullable paymentRequest, NSError * _Nullable error) {
        if (error) {
            reject(@"APPLE_PAY_PAYMENT_REQUEST_FAILED", error.localizedDescription, nil);
            return;
        }

        if (@available(iOS 11.0, *)) {
            paymentRequest.requiredBillingContactFields = [NSSet setWithObjects:PKContactFieldPostalAddress, PKContactFieldName, PKContactFieldPhoneNumber, nil];
        }
        if (options[@"requestShipping"]) {
            if (@available(iOS 11.0, *)) {
                paymentRequest.requiredShippingContactFields = [NSSet setWithObjects:PKContactFieldPostalAddress, nil];
            }
        }
        paymentRequest.merchantCapabilities = PKMerchantCapability3DS;
        paymentRequest.merchantIdentifier = merchantIdentifier;

        NSMutableArray <PKPaymentSummaryItem *> * _paymentSummaryItems = [NSMutableArray array];
        for (NSDictionary *paymentSummaryItem in paymentSummaryItems) {
            NSDecimalNumber *decimalNumberAmount = [NSDecimalNumber decimalNumberWithString:paymentSummaryItem[@"amount"]];
            PKPaymentSummaryItem *psi = [PKPaymentSummaryItem summaryItemWithLabel:paymentSummaryItem[@"label"] amount:decimalNumberAmount];
            [_paymentSummaryItems addObject: psi];
        }

        //add the total as the last item
        [_paymentSummaryItems addObject: [PKPaymentSummaryItem summaryItemWithLabel:companyName amount:[NSDecimalNumber decimalNumberWithString:amount]]];
        paymentRequest.paymentSummaryItems = _paymentSummaryItems;

        if (shippingMethods) {
            NSMutableArray <PKShippingMethod *> * _shippingMethods = [NSMutableArray array];
            for (NSDictionary *shippingMethod in shippingMethods) {
                NSDecimalNumber *decimalNumberAmount = [NSDecimalNumber decimalNumberWithString:shippingMethod[@"amount"]];
                PKShippingMethod *sm = [PKShippingMethod summaryItemWithLabel:shippingMethod[@"label"] amount:decimalNumberAmount];
                if ([shippingMethod[@"detail"] isKindOfClass:[NSString class]]) {
                    sm.detail = shippingMethod[@"detail"];
                } else {
                    sm.detail = @"";
                }

                if ([shippingMethod[@"identifier"] isKindOfClass:[NSString class]]) {
                    sm.identifier = shippingMethod[@"identifier"];
                } else {
                    sm.identifier = @"";
                }
                [_shippingMethods addObject: sm];
            }

            paymentRequest.shippingMethods = _shippingMethods;
        }

        paymentRequest.currencyCode = currencyCode;
        paymentRequest.countryCode = countryCode;

        self.resolve = resolve;
        self.reject = reject;
        [self setIsApplePaymentAuthorized:NO];
        PKPaymentAuthorizationViewController *paymentController = [[PKPaymentAuthorizationViewController alloc] initWithPaymentRequest:paymentRequest];
        paymentController.delegate = self;
        [[self reactRoot] presentViewController:paymentController animated:YES completion:NULL];
    }];
}

- (void)resetPaymentResolvers {
    self.resolve = NULL;
    self.reject = NULL;
}

#pragma mark - PKPaymentAuthorizationViewControllerDelegate
- (void)paymentAuthorizationViewController:(PKPaymentAuthorizationViewController *)controller
                       didAuthorizePayment:(PKPayment *)payment
                                completion:(void (^)(PKPaymentAuthorizationStatus))completion {
    [self setIsApplePaymentAuthorized: YES];
    BTApplePayClient *applePayClient = [[BTApplePayClient alloc] initWithAPIClient:self.apiClient];
    [applePayClient tokenizeApplePayPayment:payment
                                 completion:^(BTApplePayCardNonce *tokenizedApplePayPayment, NSError *error) {
        if (!tokenizedApplePayPayment && self.reject) {
            self.reject(error.localizedDescription, error.localizedDescription, error);
            completion(PKPaymentAuthorizationStatusFailure);
            [self resetPaymentResolvers];
            return;
        }
        [self.dataCollector collectDeviceData:^(NSString * _Nonnull deviceData) {
            if (self.resolve) {

                NSDictionary *billingAddress = @{
                                                 @"name": [NSString stringWithFormat:@"%@ %@", payment.billingContact.name.givenName, payment.billingContact.name.familyName],
                                                 @"addressLine": payment.billingContact.postalAddress.street,
                                                 @"city": payment.billingContact.postalAddress.city,
                                                 @"region": payment.billingContact.postalAddress.state,
                                                 @"country": [payment.billingContact.postalAddress.ISOCountryCode uppercaseString],
                                                 @"postalCode": payment.billingContact.postalAddress.postalCode,
                                                 @"phone": (!payment.billingContact.phoneNumber || payment.billingContact.phoneNumber.stringValue.length == 0) ? [NSNull null] : payment.billingContact.phoneNumber,
                                                 };
                NSDictionary *shippingAddress = @{};

                if(payment.shippingContact){
                            shippingAddress = @{
                                                 @"addressLine": payment.shippingContact.postalAddress.street,
                                                 @"city": payment.shippingContact.postalAddress.city,
                                                 @"region": payment.shippingContact.postalAddress.state,
                                                 @"country": [payment.shippingContact.postalAddress.ISOCountryCode uppercaseString],
                                                 @"postalCode": payment.shippingContact.postalAddress.postalCode,
                                                 };
                }

                self.resolve(@{@"deviceData": deviceData,
                               @"billing_address": billingAddress,
                               @"shipping_address": shippingAddress,
                               @"nonce": tokenizedApplePayPayment.nonce,
                               @"type": tokenizedApplePayPayment.type});
                completion(PKPaymentAuthorizationStatusSuccess);
                [self resetPaymentResolvers];
            }
        }];
    }];
}

- (void)paymentAuthorizationViewControllerDidFinish:(nonnull PKPaymentAuthorizationViewController *)controller {
    [controller dismissViewControllerAnimated:YES completion:NULL];
    if (self.reject && [self isApplePaymentAuthorized]) {
        self.reject(@"APPLE_PAY_FAILED", @"Apple Pay failed", nil);
    }
    if (self.reject && self.isApplePaymentAuthorized == NO) {
        self.reject(@"USER_CANCELLATION", @"The user cancelled", nil);
    }
    [self resetPaymentResolvers];
    self.isApplePaymentAuthorized = NULL;
}

#pragma mark - RootController
- (UIViewController*)reactRoot {
    UIViewController *topViewController  = [UIApplication sharedApplication].keyWindow.rootViewController;
    if (topViewController.presentedViewController) {
        topViewController = topViewController.presentedViewController;
    }
    return topViewController;
}


- (PKPaymentSummaryItem *_Nonnull)convertDisplayItemToPaymentSummaryItem:(NSDictionary *_Nonnull)displayItem;
{
    NSDecimalNumber *decimalNumberAmount = [NSDecimalNumber decimalNumberWithString:displayItem[@"amount"]];
    PKPaymentSummaryItem *paymentSummaryItem = [PKPaymentSummaryItem summaryItemWithLabel:displayItem[@"label"] amount:decimalNumberAmount];

    return paymentSummaryItem;
}
@end
