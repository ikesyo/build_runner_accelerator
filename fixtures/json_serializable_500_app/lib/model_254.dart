import 'package:json_annotation/json_annotation.dart';

part 'model_254.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model254 {
  const Model254({required this.id, required this.value});

  final int id;
  final String value;

  factory Model254.fromJson(Map<String, dynamic> json) =>
      _$Model254FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model254ToJson(this);
}
