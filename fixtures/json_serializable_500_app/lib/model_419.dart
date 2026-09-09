import 'package:json_annotation/json_annotation.dart';

part 'model_419.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model419 {
  const Model419({required this.id, required this.value});

  final int id;
  final String value;

  factory Model419.fromJson(Map<String, dynamic> json) =>
      _$Model419FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model419ToJson(this);
}
