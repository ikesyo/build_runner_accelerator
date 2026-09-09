import 'package:json_annotation/json_annotation.dart';

part 'model_456.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model456 {
  const Model456({required this.id, required this.value});

  final int id;
  final String value;

  factory Model456.fromJson(Map<String, dynamic> json) =>
      _$Model456FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model456ToJson(this);
}
