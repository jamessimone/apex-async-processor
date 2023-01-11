public class ContactAsyncProcessor extends AsyncProcessor {
  protected override void innerExecute(List<SObject> records) {
    Map<Id, Account> accountsToUpdate = new Map<Id, Account>();

    for (Contact con : (List<Contact>) records) {
      accountsToUpdate.put(
        con.AccountId,
        new Account(
          Id = con.AccountId,
          Name = con.FirstName + ' ' + con.LastName
        )
      );
    }

    update accountsToUpdate.values();
  }
}
