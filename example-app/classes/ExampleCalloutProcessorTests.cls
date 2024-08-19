@IsTest
private class ExampleCalloutProcessorTests {
  @IsTest
  static void worksWithOverTwoHundredRecordsQueueable() {
    List<Account> records = new List<Account>();
    for (Integer i = 0; i < 200; i++) {
      String currentIndexString = '' + i;
      records.add(
        new Account(
          Id = '001' + '0'.repeat(12 - currentIndexString.length()) + i,
          Name = 'bulkCallout' + i
        )
      );
    }
    Test.setMock(HttpCalloutMock.class, new ExampleCalloutProcessorMock());

    Test.startTest();
    new ExampleCalloutProcessor().get(records).kickoff();
    Test.stopTest();

    Assert.areEqual(
      2,
      [
        SELECT COUNT()
        FROM AsyncApexJob
        WHERE
          Status = 'Completed'
          AND JobType = 'Queueable'
          AND ApexClass.Name = 'AsyncProcessor'
      ],
      'Expected to see 2 AsyncApexJob initiated by test.'
    );
  }

  @IsTest
  static void worksWithOverTwoHundredRecordsBatch() {
    List<Account> records = new List<Account>();
    for (Integer i = 0; i < 200; i++) {
      String currentIndexString = '' + i;
      records.add(
        new Account(
          Id = '001' + '0'.repeat(12 - currentIndexString.length()) + i,
          Name = 'bulkCallout' + i
        )
      );
    }
    Test.setMock(HttpCalloutMock.class, new ExampleCalloutProcessorMock());

    Test.startTest();
    ExampleCalloutProcessor proc = new ExampleCalloutProcessor();
    proc.overrideBatchLimit = true;
    proc.get(records).kickoff();
    Test.stopTest();

    Assert.areEqual(
      2,
      [
        SELECT COUNT()
        FROM AsyncApexJob
        WHERE
          Status = 'Completed'
          AND ApexClass.Name IN ('AsyncProcessor', 'ExampleCalloutProcessor')
          AND JobType IN ('Queueable', 'BatchApexWorker')
      ],
      '' +
      [
        SELECT COUNT(Id), ApexClass.Name className, JobType jobType
        FROM AsyncApexJob
        GROUP BY ApexClass.Name, JobType
      ]
    );
  }

  private class ExampleCalloutProcessorMock implements System.HttpCalloutMock {
    public HttpResponse respond(HttpRequest req) {
      return new HttpResponse();
    }
  }
}
