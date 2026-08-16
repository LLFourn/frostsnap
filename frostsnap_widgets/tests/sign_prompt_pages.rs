use core::str::FromStr;
use frostsnap_core::bitcoin_transaction::PromptSignBitcoinTx;
use frostsnap_widgets::sign_prompt::{
    AddressPage, AmountPage, ConfirmationPage, FeePage, SignPromptPageList, WarningPage,
};
use frostsnap_widgets::widget_list::WidgetList;

fn prompt(foreign_sats: &[u64], self_payment: Option<u64>, fee: u64) -> PromptSignBitcoinTx {
    let address = bitcoin::Address::from_str(
        "bc1p5d7rjq7g6rdk2yhzks9smlaqtedr4dekq08ge8ztwac72sfr9rusxg3297",
    )
    .unwrap()
    .assume_checked();
    PromptSignBitcoinTx {
        foreign_recipients: foreign_sats
            .iter()
            .map(|&sats| (address.clone(), bitcoin::Amount::from_sat(sats)))
            .collect(),
        self_payment: self_payment.map(bitcoin::Amount::from_sat),
        fee: bitcoin::Amount::from_sat(fee),
        fee_rate_sats_per_vbyte: Some(1.0),
    }
}

fn pages(prompt: PromptSignBitcoinTx) -> SignPromptPageList {
    SignPromptPageList::new_with_seed(prompt, 0)
}

fn page_is<W: 'static>(list: &SignPromptPageList, index: usize) -> bool {
    list.get(index)
        .expect("page exists")
        .widget
        .downcast_ref::<W>()
        .is_some()
}

#[test]
fn pure_self_spend_shows_self_amount_fee_and_confirm() {
    let list = pages(prompt(&[], Some(1_000_000), 10_000));
    assert_eq!(list.len(), 3);
    assert!(page_is::<AmountPage>(&list, 0));
    assert!(page_is::<FeePage>(&list, 1));
    assert!(page_is::<ConfirmationPage>(&list, 2));
}

#[test]
fn pure_self_spend_can_trigger_the_proportional_fee_warning() {
    let list = pages(prompt(&[], Some(1_000_000), 60_000));
    assert_eq!(list.len(), 4);
    assert!(page_is::<AmountPage>(&list, 0));
    assert!(page_is::<WarningPage>(&list, 1));
    assert!(page_is::<FeePage>(&list, 2));
    assert!(page_is::<ConfirmationPage>(&list, 3));
}

#[test]
fn ordinary_send_pages_are_unchanged() {
    let list = pages(prompt(&[500_000], None, 10_000));
    assert_eq!(list.len(), 4);
    assert!(page_is::<AmountPage>(&list, 0));
    assert!(page_is::<AddressPage>(&list, 1));
    assert!(page_is::<FeePage>(&list, 2));
    assert!(page_is::<ConfirmationPage>(&list, 3));
}

#[test]
fn self_payment_page_comes_after_recipient_pages() {
    let list = pages(prompt(&[500_000], Some(300_000), 10_000));
    assert_eq!(list.len(), 5);
    assert!(page_is::<AmountPage>(&list, 0));
    assert!(page_is::<AddressPage>(&list, 1));
    assert!(page_is::<AmountPage>(&list, 2));
    assert!(page_is::<FeePage>(&list, 3));
    assert!(page_is::<ConfirmationPage>(&list, 4));
}

#[test]
fn fee_warning_denominator_includes_the_self_payment() {
    let with_self = pages(prompt(&[1_000_000], Some(1_000_000), 60_000));
    assert_eq!(with_self.len(), 5);
    assert!(page_is::<FeePage>(&with_self, 3));

    let without_self = pages(prompt(&[1_000_000], None, 60_000));
    assert_eq!(without_self.len(), 5);
    assert!(page_is::<WarningPage>(&without_self, 2));
}

#[test]
fn absolute_fee_threshold_fires_even_when_nothing_moves() {
    let list = pages(prompt(&[], Some(0), 150_000));
    assert_eq!(list.len(), 4);
    assert!(page_is::<WarningPage>(&list, 1));
}
