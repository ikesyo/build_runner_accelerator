import 'package:json_annotation/json_annotation.dart';

part 'model_096.g.dart';

// benchmark marker: 0
@JsonSerializable()
class Model096 {
  const Model096({required this.id, required this.value});

  final int id;
  final String value;

  factory Model096.fromJson(Map<String, dynamic> json) =>
      _$Model096FromJson(json);

  Map<String, dynamic> toJson() =>
      _$Model096ToJson(this);
}
