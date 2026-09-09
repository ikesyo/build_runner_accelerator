import 'package:json_annotation/json_annotation.dart';

part 'model_484.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model484 {
  const Model484({required this.id, required this.value});

  final int id;
  final String value;

  factory Model484.fromJson(Map<String, dynamic> json) =>
      _$Model484FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model484ToJson(this);
}
