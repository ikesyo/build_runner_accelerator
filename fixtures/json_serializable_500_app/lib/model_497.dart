import 'package:json_annotation/json_annotation.dart';

part 'model_497.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model497 {
  const Model497({required this.id, required this.value});

  final int id;
  final String value;

  factory Model497.fromJson(Map<String, dynamic> json) =>
      _$Model497FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model497ToJson(this);
}
