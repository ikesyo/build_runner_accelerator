import 'package:json_annotation/json_annotation.dart';

part 'model_202.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model202 {
  const Model202({required this.id, required this.value});

  final int id;
  final String value;

  factory Model202.fromJson(Map<String, dynamic> json) =>
      _$Model202FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model202ToJson(this);
}
