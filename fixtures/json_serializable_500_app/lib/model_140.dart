import 'package:json_annotation/json_annotation.dart';

part 'model_140.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model140 {
  const Model140({required this.id, required this.value});

  final int id;
  final String value;

  factory Model140.fromJson(Map<String, dynamic> json) =>
      _$Model140FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model140ToJson(this);
}
