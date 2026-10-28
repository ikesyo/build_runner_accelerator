import 'package:json_annotation/json_annotation.dart';
part 'model.g.dart';
@JsonSerializable()
class Example {
  Example(this.value);
  final int value;
  factory Example.fromJson(Map<String, dynamic> json) => _$ExampleFromJson(json);
  Map<String, dynamic> toJson() => _$ExampleToJson(this);
}
