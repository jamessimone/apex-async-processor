public virtual class ExampleCalloutProcessor extends AsyncProcessor {
  public Boolean overrideBatchLimit = false;

  protected override void innerExecute(List<SObject> records) {
    while (records.isEmpty() == false) {
      System.debug('Making callout');
      records.remove(0);
      HttpRequest req = new HttpRequest();
      req.setMethod('GET');
      req.setEndpoint('https://example.com');
      new Http().send(req);
    }
  }

  protected override Integer getQueueableChunkSize() {
    return System.Limits.getLimitCallouts();
  }

  protected override Integer getLimitToBatch() {
    return this.overrideBatchLimit ? 1 : super.getLimitToBatch();
  }

  protected override Integer getBatchChunkSize() {
    return this.getQueueableChunkSize();
  }
}
